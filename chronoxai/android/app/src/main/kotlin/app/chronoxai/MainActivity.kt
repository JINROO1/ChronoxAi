package app.chronoxai

import android.Manifest
import android.app.Activity
import android.app.ActivityManager
import android.content.Intent
import android.speech.RecognizerIntent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Debug
import android.os.PowerManager
import android.os.StatFs
import android.provider.Settings
import android.system.Os
import android.system.OsConstants
import androidx.annotation.NonNull
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.io.File
import java.io.FileOutputStream
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import android.util.Base64

/**
 * Actividad principal.
 *
 * El PTY de la terminal se crea en Dart mediante flutter_pty; aquí quedan los
 * canales de plataforma para datos Android, permisos, voz y almacenamiento seguro.
 */
class MainActivity : FlutterActivity() {

    private val platformChannel = "app.chronoxai/platform"
    private val permissionsChannel = "app.chronoxai/permissions"
    private val schedulerChannelName = "app.chronoxai/scheduler"
    private val voiceChannelName = "app.chronoxai/voice"
    private val secureStoreChannelName = "app.chronoxai/secure_store"
    private val projectExportChannelName = "app.chronoxai/project_export"
    private val localLlmChannelName = "app.chronoxai/local_llm"
    private val localLlmEventsChannelName = "app.chronoxai/local_llm_events"
    private val localLlmExecutor: ExecutorService = Executors.newSingleThreadExecutor()
    private val localLlmLifecycleLock = Any()
    @Volatile private var localLlmHandle: Long = 0L
    @Volatile private var localLlmGenerating = false
    @Volatile private var localLlmShuttingDown = false
    @Volatile private var localLlmEventSink: EventChannel.EventSink? = null
    private val projectExportRequestCode = 4004
    private val localModelPickerRequestCode = 4005
    private var pendingLocalModelPickerResult: MethodChannel.Result? = null
    private var pendingProjectExportResult: MethodChannel.Result? = null
    private var pendingProjectExportPath: String? = null

    /** Resultado pendiente del diálogo de permisos, que es asíncrono. */
    private var pendingPermissionResult: MethodChannel.Result? = null
    private val notificationRequestCode = 4001
    private val voiceRequestCode = 4002
    private val voiceActivityRequestCode = 4003
    private var pendingVoiceResult: MethodChannel.Result? = null

    override fun onDestroy() {
        val handle = synchronized(localLlmLifecycleLock) {
            localLlmShuttingDown = true
            localLlmEventSink = null
            val active = localLlmHandle
            localLlmHandle = 0L
            active
        }
        if (handle != 0L) nativeCancel(handle)
        // The single-thread executor serializes teardown behind any active load
        // or generation, preventing use-after-free of the native context.
        localLlmExecutor.execute {
            if (handle != 0L) nativeUnloadModel(handle)
            localLlmExecutor.shutdown()
        }
        super.onDestroy()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
    }

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Android 15 obliga a dibujar hasta los bordes; sin esto, en API 35 la
        // app sale con barras de sistema opacas pase lo que pase en Dart.
        if (Build.VERSION.SDK_INT >= 35) {
            window.setDecorFitsSystemWindows(false)
        }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            platformChannel,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "facts" -> result.success(platformFacts())
                "repairRootfsExecutableBits" -> {
                    val root = call.argument<String>("root")
                    if (root.isNullOrBlank()) {
                        result.error("invalid_root", "Falta la ruta del rootfs.", null)
                    } else {
                        Thread({
                            try {
                                val repaired = repairRootfsExecutableBits(root)
                                runOnUiThread { result.success(repaired) }
                            } catch (error: Exception) {
                                runOnUiThread {
                                    result.error("repair_failed", error.message, null)
                                }
                            }
                        }, "chronox-rootfs-mode-repair").start()
                    }
                }
                else -> result.notImplemented()
            }
        }

        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            localLlmEventsChannelName,
        ).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                localLlmEventSink = events
            }

            override fun onCancel(arguments: Any?) {
                localLlmEventSink = null
            }
        })

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            localLlmChannelName,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "availableStorageBytes" -> {
                    try {
                        result.success(StatFs(filesDir.absolutePath).availableBytes)
                    } catch (error: Exception) {
                        result.error("storage_unavailable", error.message, null)
                    }
                }
                "deviceDiagnostics" -> {
                    try {
                        val memory = ActivityManager.MemoryInfo()
                        (getSystemService(ACTIVITY_SERVICE) as ActivityManager)
                            .getMemoryInfo(memory)
                        val debugMemory = Debug.MemoryInfo()
                        Debug.getMemoryInfo(debugMemory)
                        fun statusKilobytes(label: String): Long? = try {
                            File("/proc/self/status").useLines { lines ->
                                lines.firstOrNull { it.startsWith("$label:") }
                                    ?.substringAfter(':')
                                    ?.trim()
                                    ?.substringBefore(' ')
                                    ?.toLongOrNull()
                                    ?.times(1024L)
                            }
                        } catch (_: Exception) {
                            null
                        }
                        result.success(mapOf(
                            "rssBytes" to statusKilobytes("VmRSS"),
                            "peakRssBytes" to statusKilobytes("VmHWM"),
                            "pssBytes" to debugMemory.totalPss.toLong() * 1024L,
                            "availableRamBytes" to memory.availMem,
                            "totalRamBytes" to memory.totalMem,
                            "apiLevel" to Build.VERSION.SDK_INT,
                            "abi" to Build.SUPPORTED_ABIS.firstOrNull().orEmpty(),
                        ))
                    } catch (error: Exception) {
                        result.error("diagnostics_unavailable", error.message, null)
                    }
                }
                "pickModelFile" -> {
                    if (pendingLocalModelPickerResult != null) {
                        result.error("picker_busy", "Ya hay un selector de modelo abierto.", null)
                    } else {
                        pendingLocalModelPickerResult = result
                        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                            addCategory(Intent.CATEGORY_OPENABLE)
                            type = "*/*"
                            putExtra(Intent.EXTRA_MIME_TYPES, arrayOf(
                                "application/octet-stream",
                                "application/x-gguf",
                            ))
                        }
                        try {
                            startActivityForResult(intent, localModelPickerRequestCode)
                        } catch (error: Exception) {
                            pendingLocalModelPickerResult = null
                            result.error("picker_unavailable", error.message, null)
                        }
                    }
                }
                "loadModel" -> {
                    val path = call.argument<String>("path")
                    if (path.isNullOrBlank()) {
                        result.error("invalid_model_path", "Falta la ruta del modelo.", null)
                    } else {
                        val contextSize = call.argument<Int>("contextSize") ?: 2048
                        val threads = call.argument<Int>("threads") ?: 4
                        if (contextSize !in 128..8192 || threads !in 1..8) {
                            result.error(
                                "invalid_model_options",
                                "Contexto o número de hilos fuera de los límites admitidos.",
                                null,
                            )
                            return@setMethodCallHandler
                        }
                        localLlmExecutor.execute {
                            try {
                                val oldHandle = synchronized(localLlmLifecycleLock) {
                                    val active = localLlmHandle
                                    localLlmHandle = 0L
                                    active
                                }
                                if (oldHandle != 0L) nativeUnloadModel(oldHandle)
                                val loaded = nativeLoadModel(path, contextSize, threads)
                                val rejectedDuringShutdown = synchronized(localLlmLifecycleLock) {
                                    if (localLlmShuttingDown) {
                                        true
                                    } else {
                                        localLlmHandle = loaded
                                        false
                                    }
                                }
                                if (rejectedDuringShutdown) {
                                    nativeUnloadModel(loaded)
                                } else {
                                    runOnUiThread {
                                        if (!localLlmShuttingDown) result.success(null)
                                    }
                                }
                            } catch (error: Exception) {
                                runOnUiThread {
                                    result.error("model_load_failed", error.message, null)
                                }
                            }
                        }
                    }
                }
                "generate" -> {
                    val roles = call.argument<List<String>>("roles")
                    val contents = call.argument<List<String>>("contents")
                    val handle = localLlmHandle
                    val maxTokens = call.argument<Int>("maxTokens") ?: 256
                    val temperature = call.argument<Double>("temperature")?.toFloat() ?: 0.7f
                    val allowedRoles = setOf("system", "user", "assistant", "tool")
                    val contentBytes = contents?.sumOf {
                        it.toByteArray(Charsets.UTF_8).size.toLong()
                    } ?: 0L
                    if (maxTokens !in 1..2048 || !temperature.isFinite() || temperature !in 0f..2f) {
                        result.error("invalid_generation_options", "Límites de generación local inválidos.", null)
                    } else if (handle == 0L || roles == null || contents == null || roles.isEmpty() ||
                        roles.size != contents.size || roles.size > 128 || roles.any { it !in allowedRoles } ||
                        contentBytes > 2L * 1024L * 1024L) {
                        result.error("model_not_ready", "Modelo o mensajes no válidos.", null)
                    } else if (localLlmGenerating) {
                        result.error("generation_busy", "Ya hay una generación en curso.", null)
                    } else {
                        localLlmGenerating = true
                        result.success(null)
                        localLlmExecutor.execute {
                            try {
                                val canStart = synchronized(localLlmLifecycleLock) {
                                    if (localLlmShuttingDown || localLlmHandle != handle) {
                                        false
                                    } else {
                                        nativeResetCancellation(handle)
                                        true
                                    }
                                }
                                if (!canStart) {
                                    runOnUiThread {
                                        localLlmEventSink?.success(mapOf(
                                            "type" to "error",
                                            "message" to "La sesión local se cerró antes de iniciar la generación.",
                                        ))
                                    }
                                } else {
                                    nativeGenerate(
                                        handle,
                                        roles.toTypedArray(),
                                        contents.toTypedArray(),
                                        maxTokens,
                                        temperature,
                                        LocalTokenSink(
                                            send = { text ->
                                                runOnUiThread {
                                                    localLlmEventSink?.success(
                                                        mapOf("type" to "text", "text" to text),
                                                    )
                                                }
                                            },
                                            sendMetrics = { tokens, elapsedMs ->
                                                runOnUiThread {
                                                    localLlmEventSink?.success(mapOf(
                                                        "type" to "metrics",
                                                        "tokens" to tokens,
                                                        "elapsedMs" to elapsedMs,
                                                    ))
                                                }
                                            },
                                        ),
                                    )
                                    runOnUiThread {
                                        localLlmEventSink?.success(mapOf("type" to "done"))
                                    }
                                }
                            } catch (error: Exception) {
                                runOnUiThread {
                                    localLlmEventSink?.success(mapOf(
                                        "type" to "error",
                                        "message" to (error.message ?: "Error de inferencia local."),
                                    ))
                                }
                            } finally {
                                localLlmGenerating = false
                            }
                        }
                    }
                }
                "cancel" -> {
                    val handle = localLlmHandle
                    if (handle != 0L) nativeCancel(handle)
                    result.success(null)
                }
                "unloadModel" -> {
                    val handle = synchronized(localLlmLifecycleLock) {
                        val active = localLlmHandle
                        localLlmHandle = 0L
                        active
                    }
                    localLlmExecutor.execute {
                        if (handle != 0L) nativeUnloadModel(handle)
                        runOnUiThread { result.success(null) }
                    }
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            projectExportChannelName,
        ).setMethodCallHandler { call, result ->
            if (call.method != "saveZip") {
                result.notImplemented()
            } else if (pendingProjectExportResult != null) {
                result.error("export_busy", "Ya hay una exportación en curso.", null)
            } else {
                val path = call.argument<String>("path")
                val fileName = call.argument<String>("fileName")
                if (path.isNullOrBlank() || fileName.isNullOrBlank()) {
                    result.error("invalid_export", "Faltan los datos del archivo.", null)
                } else {
                    pendingProjectExportPath = path
                    pendingProjectExportResult = result
                    val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                        addCategory(Intent.CATEGORY_OPENABLE)
                        type = "application/zip"
                        putExtra(Intent.EXTRA_TITLE, fileName)
                    }
                    try {
                        startActivityForResult(intent, projectExportRequestCode)
                    } catch (error: Exception) {
                        pendingProjectExportResult = null
                        pendingProjectExportPath = null
                        result.error("export_picker", error.message, null)
                    }
                }
            }
        }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            secureStoreChannelName,
        ).setMethodCallHandler { call, result ->
            val key = call.argument<String>("key")
            if (key.isNullOrBlank()) {
                result.error("invalid_key", "Falta la clave del secreto.", null)
            } else {
                try {
                    val prefs = getSharedPreferences("encrypted_secrets", MODE_PRIVATE)
                    when (call.method) {
                        "keys" -> result.success(prefs.all.keys.filter { it.startsWith(key) }.sorted())
                        "read" -> result.success(prefs.getString(key, null)?.let(::decryptSecret))
                        "write" -> {
                            val value = call.argument<String>("value")
                                ?: throw IllegalArgumentException("Falta el valor.")
                            prefs.edit().putString(key, encryptSecret(value)).apply()
                            result.success(null)
                        }
                        "delete" -> { prefs.edit().remove(key).apply(); result.success(null) }
                        else -> result.notImplemented()
                    }
                } catch (error: Exception) {
                    result.error("secure_store_error", error.message, null)
                }
            }
        }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            voiceChannelName,
        ).setMethodCallHandler { call, result ->
            if (call.method != "recognize") {
                result.notImplemented()
            } else if (pendingVoiceResult != null) {
                result.error("voice_busy", "Ya hay un reconocimiento en curso.", null)
            } else {
                pendingVoiceResult = result
                if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) {
                    launchRecognition()
                } else {
                    requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), voiceRequestCode)
                }
            }
        }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            schedulerChannelName,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "schedule" -> {
                    val id = call.argument<String>("id")
                    val prompt = call.argument<String>("prompt")
                    val atMillis = call.argument<Long>("atMillis")
                    if (id.isNullOrBlank() || prompt.isNullOrBlank() || atMillis == null) {
                        result.error("invalid_task", "Faltan datos de la tarea.", null)
                    } else {
                        val repeatDays = call.argument<Int>("repeatDays") ?: 0
                        result.success(schedulePrompt(id, prompt, atMillis, repeatDays))
                    }
                }
                "cancel" -> {
                    val id = call.argument<String>("id")
                    if (id == null) result.error("invalid_task", "Falta el id.", null)
                    else { cancelPrompt(id); result.success(null) }
                }
                "takeLaunchPrompt" -> {
                    result.success(intent.getStringExtra(ScheduledPromptReceiver.EXTRA_PROMPT))
                    intent.removeExtra(ScheduledPromptReceiver.EXTRA_PROMPT)
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            permissionsChannel,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "requestNotifications" -> requestNotifications(result)
                "isBatteryUnrestricted" -> result.success(isBatteryUnrestricted())
                "requestBatteryUnrestricted" -> {
                    requestBatteryUnrestricted()
                    result.success(null)
                }
                "startTerminalService" -> {
                    val title = call.argument<String>("title") ?: "Sesión activa"
                    result.success(startTerminalService(title))
                }
                "stopTerminalService" -> {
                    TerminalService.stop(this)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun schedulePrompt(id: String, prompt: String, atMillis: Long, repeatDays: Int): Boolean {
        val alarm = getSystemService(ALARM_SERVICE) as android.app.AlarmManager
        val taskIntent = Intent(this, ScheduledPromptReceiver::class.java).apply {
            putExtra(ScheduledPromptReceiver.EXTRA_ID, id)
            putExtra(ScheduledPromptReceiver.EXTRA_PROMPT, prompt)
            putExtra(ScheduledPromptReceiver.EXTRA_REPEAT_DAYS, repeatDays)
        }
        val pending = android.app.PendingIntent.getBroadcast(
            this, id.hashCode(), taskIntent,
            android.app.PendingIntent.FLAG_UPDATE_CURRENT or android.app.PendingIntent.FLAG_IMMUTABLE,
        )
        alarm.setAndAllowWhileIdle(android.app.AlarmManager.RTC_WAKEUP, atMillis, pending)
        return true
    }

    private fun cancelPrompt(id: String) {
        val taskIntent = Intent(this, ScheduledPromptReceiver::class.java)
        val pending = android.app.PendingIntent.getBroadcast(
            this, id.hashCode(), taskIntent,
            android.app.PendingIntent.FLAG_NO_CREATE or android.app.PendingIntent.FLAG_IMMUTABLE,
        )
        if (pending != null) {
            (getSystemService(ALARM_SERVICE) as android.app.AlarmManager).cancel(pending)
            pending.cancel()
        }
    }

    /**
     * Pide POST_NOTIFICATIONS (API 33+).
     *
     * El resultado llega en `onRequestPermissionsResult`, así que la llamada de
     * Dart queda pendiente hasta entonces. Si el usuario pulsa "no" devolvemos
     * `false` y la app sigue funcionando: solo pierde la notificación.
     */
    private fun requestNotifications(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            result.success(true)
            return
        }
        val granted = checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
        if (granted) {
            result.success(true)
            return
        }
        if (pendingPermissionResult != null) {
            // Dos peticiones a la vez: se responde a la anterior para no dejarla
            // colgada (Dart se quedaría esperando para siempre).
            pendingPermissionResult?.success(false)
        }
        pendingPermissionResult = result
        requestPermissions(
            arrayOf(Manifest.permission.POST_NOTIFICATIONS),
            notificationRequestCode,
        )
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == voiceRequestCode) {
            if (grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED) {
                launchRecognition()
            } else {
                pendingVoiceResult?.error("voice_permission", "Se necesita permiso de micrófono.", null)
                pendingVoiceResult = null
            }
            return
        }
        if (requestCode != notificationRequestCode) return
        val granted = grantResults.isNotEmpty() &&
            grantResults[0] == PackageManager.PERMISSION_GRANTED
        pendingPermissionResult?.success(granted)
        pendingPermissionResult = null
    }

    private fun launchRecognition() {
        val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
            putExtra(RecognizerIntent.EXTRA_PROMPT, "Habla ahora")
            putExtra(RecognizerIntent.EXTRA_LANGUAGE, java.util.Locale.getDefault().toLanguageTag())
        }
        try {
            startActivityForResult(intent, voiceActivityRequestCode)
        } catch (error: Throwable) {
            pendingVoiceResult?.error("voice_unavailable", "El reconocimiento de voz no está disponible.", error.message)
            pendingVoiceResult = null
        }
    }

    @Deprecated("SpeechRecognizer result returned through the platform channel")
    /**
     * Copies the SAF document to a unique private-cache file for Dart to hash and
     * atomically install. Do not read arbitrary-size documents into cache: the
     * catalog's largest pinned Qwen GGUF is 1,280,835,840 bytes. Check available
     * space before and during copying, preserve a reserve for app/system work,
     * and remove partials after any exception or process-retry.
     */
    private fun copyPickedModelToCache(uri: Uri): File {
        val maximumBytes = 1_280_835_840L
        val reserveBytes = 128L * 1024L * 1024L
        val importDirectory = File(cacheDir, "model-imports").apply { mkdirs() }
        val staleBefore = System.currentTimeMillis() - 24L * 60L * 60L * 1000L
        importDirectory.listFiles()?.forEach { file ->
            if (file.lastModified() < staleBefore) file.delete()
        }

        val expectedBytes = contentResolver.openAssetFileDescriptor(uri, "r")?.use {
            it.length.takeIf { length -> length > 0L }
        }
        if (expectedBytes != null && expectedBytes > maximumBytes) {
            throw IllegalArgumentException("El archivo supera el tamaño máximo admitido para Qwen.")
        }
        // SAF providers sometimes report UNKNOWN_LENGTH (for example a cloud
        // document). In that case reserve a small floor and enforce the byte
        // cap plus free-space reserve as the stream advances.
        val requiredBeforeCopy = (expectedBytes ?: 0L) + reserveBytes
        if (StatFs(cacheDir.absolutePath).availableBytes < requiredBeforeCopy) {
            throw IllegalStateException("No hay espacio suficiente para preparar la importación del modelo.")
        }

        val temporary = File.createTempFile("picked-model-", ".part", importDirectory)
        val destination = File(importDirectory, "${temporary.name.removeSuffix(".part")}.gguf")
        try {
            val input = contentResolver.openInputStream(uri)
                ?: throw IllegalStateException("No se pudo leer el archivo elegido.")
            input.use { source ->
                FileOutputStream(temporary).use { output ->
                    val buffer = ByteArray(1024 * 1024)
                    var copied = 0L
                    var sinceSpaceCheck = 0L
                    while (true) {
                        val count = source.read(buffer)
                        if (count < 0) break
                        copied += count
                        sinceSpaceCheck += count
                        if (copied > maximumBytes) {
                            throw IllegalArgumentException("El archivo supera el tamaño máximo admitido para Qwen.")
                        }
                        if (sinceSpaceCheck >= 8L * 1024L * 1024L) {
                            if (StatFs(cacheDir.absolutePath).availableBytes < reserveBytes) {
                                throw IllegalStateException("Se agotó el espacio reservado durante la importación.")
                            }
                            sinceSpaceCheck = 0L
                        }
                        output.write(buffer, 0, count)
                    }
                    if (expectedBytes != null && copied != expectedBytes) {
                        throw IllegalStateException("El archivo cambió de tamaño durante la importación SAF.")
                    }
                    output.fd.sync()
                }
            }
            if (!temporary.renameTo(destination)) {
                throw IllegalStateException("No se pudo publicar el archivo temporal de importación.")
            }
            return destination
        } catch (error: Exception) {
            temporary.delete()
            destination.delete()
            throw error
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == localModelPickerRequestCode) {
            val result = pendingLocalModelPickerResult
            pendingLocalModelPickerResult = null
            val uri = data?.data
            if (resultCode != Activity.RESULT_OK || uri == null) {
                result?.success(null)
            } else {
                Thread({
                    try {
                        val copied = copyPickedModelToCache(uri)
                        runOnUiThread { result?.success(copied.absolutePath) }
                    } catch (error: Exception) {
                        runOnUiThread { result?.error("model_import_failed", error.message, null) }
                    }
                }, "chronox-model-import").start()
            }
            return
        }
        if (requestCode == projectExportRequestCode) {
            val result = pendingProjectExportResult
            val path = pendingProjectExportPath
            pendingProjectExportResult = null
            pendingProjectExportPath = null
            if (resultCode != Activity.RESULT_OK || data?.data == null) {
                result?.success(false)
            } else {
                try {
                    val source = File(path ?: throw IllegalStateException("Archivo temporal perdido."))
                    contentResolver.openOutputStream(data.data!!)?.use { output ->
                        source.inputStream().use { input -> input.copyTo(output) }
                    } ?: throw IllegalStateException("No se pudo abrir el destino elegido.")
                    result?.success(true)
                } catch (error: Exception) {
                    result?.error("export_failed", error.message, null)
                }
            }
            return
        }
        if (requestCode != voiceActivityRequestCode) return
        val result = pendingVoiceResult
        pendingVoiceResult = null
        if (resultCode == Activity.RESULT_OK) {
            val phrases = data?.getStringArrayListExtra(RecognizerIntent.EXTRA_RESULTS)
            result?.success(phrases?.firstOrNull())
        } else {
            result?.success(null)
        }
    }

    private fun isBatteryUnrestricted(): Boolean {
        val power = getSystemService(POWER_SERVICE) as? PowerManager ?: return false
        return power.isIgnoringBatteryOptimizations(packageName)
    }

    /**
     * Abre la pantalla del sistema para excluir la app de la optimización.
     *
     * Se intenta primero el diálogo directo (que necesita el permiso
     * REQUEST_IGNORE_BATTERY_OPTIMIZATIONS) y, si la ROM lo bloquea, se cae a la
     * lista general de optimización, que existe en todas las versiones.
     */
    private fun requestBatteryUnrestricted() {
        val direct = Intent(
            Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
            Uri.parse("package:$packageName"),
        )
        try {
            startActivity(direct)
            return
        } catch (t: Throwable) {
            // Algunas ROMs eliminan este intent; se usa el genérico.
        }
        try {
            startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
        } catch (t: Throwable) {
            // Sin ajustes accesibles no hay nada más que hacer.
        }
    }

    /**
     * Arranca el servicio en primer plano.
     *
     * Se llama siempre desde la actividad en primer plano: en API 31+ el sistema
     * lanza `ForegroundServiceStartNotAllowedException` si se intenta desde
     * segundo plano.
     */
    private fun startTerminalService(title: String): Boolean {
        return try {
            TerminalService.start(this, title)
            true
        } catch (t: Throwable) {
            false
        }
    }

    /**
     * Dart's standard File API cannot chmod extracted OCI entries. Restore the
     * executable bit for ELF files, shebang scripts, and files in Debian's
     * command directories. The rootfs is private app data and the canonical
     * path check prevents a malicious image symlink escaping that tree.
     */
    private fun repairRootfsExecutableBits(rootPath: String): Boolean {
        val root = File(rootPath).canonicalFile
        val allowedRoot = File(filesDir, "linux/rootfs").canonicalPath + File.separator
        if (!root.isDirectory || !root.path.startsWith(allowedRoot)) return false
        val rootPrefix = root.path + File.separator
        val pending = ArrayDeque<File>()
        val visited = HashSet<String>()
        pending.add(root)

        while (pending.isNotEmpty()) {
            val directory = pending.removeLast()
            val children = directory.listFiles() ?: continue
            for (entry in children) {
                val canonical = try { entry.canonicalFile } catch (_: Exception) { continue }
                if (canonical.path != root.path && !canonical.path.startsWith(rootPrefix)) continue
                // Resolve links only after containment validation above. This
                // repairs aliases such as /usr/bin/sh -> dash without allowing
                // a link to escape the private rootfs.
                if (canonical.isDirectory) {
                    if (visited.add(canonical.path)) pending.add(canonical)
                    continue
                }
                if (!canonical.isFile || !looksLikeExecutable(canonical, root)) continue
                if (!canonical.canExecute()) canonical.setExecutable(true, true)
            }
        }
        val shell = File(root, "bin/sh")
        return shell.exists() && shell.canExecute()
    }

    private fun looksLikeExecutable(file: File, root: File): Boolean {
        val relative = file.relativeTo(root).invariantSeparatorsPath
        val inCommandDirectory = relative.startsWith("bin/") ||
            relative.startsWith("sbin/") ||
            relative.startsWith("usr/bin/") ||
            relative.startsWith("usr/sbin/") ||
            relative.startsWith("usr/local/bin/") ||
            relative.startsWith("usr/local/sbin/")
        if (inCommandDirectory) return true
        return try {
            file.inputStream().use { input ->
                val first = input.read()
                val second = input.read()
                val third = input.read()
                val fourth = input.read()
                (first == 0x7f && second == 'E'.code && third == 'L'.code && fourth == 'F'.code) ||
                    (first == '#'.code && second == '!'.code)
            }
        } catch (_: Exception) {
            false
        }
    }

    private fun platformFacts(): Map<String, Any?> {
        val nativeLibDir = applicationInfo.nativeLibraryDir
        return mapOf(
            "sdkInt" to Build.VERSION.SDK_INT,
            "release" to Build.VERSION.RELEASE,
            "abi" to Build.SUPPORTED_ABIS.firstOrNull(),
            "pageSize" to pageSize(),
            "nativeLibraryDir" to nativeLibDir,
            "filesDir" to filesDir.absolutePath,
            "cacheDir" to cacheDir.absolutePath,
            "targetSdk" to applicationInfo.targetSdkVersion,
            "manufacturer" to Build.MANUFACTURER,
            "model" to Build.MODEL,
            // Lo que de verdad decide si se puede ejecutar proot.
            "selinuxEnforcing" to isSelinuxEnforcing(),
            "selinuxDomain" to selinuxDomain(),
            "canExecuteFromData" to canExecuteFromData(),
        )
    }

    /**
     * Tamaño de página real del kernel.
     *
     * Importa en Android 15+: un dispositivo con páginas de 16 KB no puede
     * cargar un ELF alineado solo a 4 KB. `sysconf` es la vía correcta; leer
     * `/proc/self/pagemap` requiere permisos que no tenemos.
     */
    private fun pageSize(): Long = try {
        Os.sysconf(OsConstants._SC_PAGESIZE)
    } catch (t: Throwable) {
        4096L
    }

    /**
     * `getenforce` no es invocable sin root, pero `/sys/fs/selinux/enforce` sí
     * es legible en la mayoría de dispositivos. Ante la duda, se asume enforcing.
     */
    private fun isSelinuxEnforcing(): Boolean = try {
        val file = File("/sys/fs/selinux/enforce")
        if (file.exists() && file.canRead()) file.readText().trim() == "1" else true
    } catch (t: Throwable) {
        true
    }

    /**
     * Dominio SELinux del proceso (`u:r:untrusted_app_27:s0:...`).
     *
     * Es el dato que de verdad decide si `execve` funciona sobre el directorio
     * privado. Android lo asigna por `targetSdk` del grupo de `sharedUserId`,
     * pero una ROM puede dejar el dominio "pegado" de una instalación anterior,
     * o meter la app en un dominio propio. Leerlo evita adivinar.
     */
    private fun selinuxDomain(): String? = try {
        val attr = File("/proc/self/attr/current")
        if (attr.exists() && attr.canRead()) {
            attr.readText().trim().substringBefore('\u0000').ifEmpty { null }
        } else {
            null
        }
    } catch (t: Throwable) {
        null
    }

    /**
     * Comprueba de verdad que se puede ejecutar un binario del APK.
     *
     * Es más fiable que cualquier heurística: `nativeLibraryDir` está etiquetado
     * como `apk_data_file` y es ejecutable incluso con `targetSdk` alto, así que
     * esto valida la ruta completa (extracción + `execve`) en el dispositivo
     * real. `libproot.so` no es un ejecutable normal, pero sí un ELF válido: el
     * kernel lo rechazará por otras razones si no hay permiso, así que hay que
     * distinguir "denegado" (EACCES/EPERM) de "es una librería" (ENOEXEC).
     */
    private fun secretKey(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        val alias = "chronoxai_mcp_secrets_v1"
        (store.getKey(alias, null) as? SecretKey)?.let { return it }
        val generator = KeyGenerator.getInstance("AES", "AndroidKeyStore")
        generator.init(android.security.keystore.KeyGenParameterSpec.Builder(
            alias,
            android.security.keystore.KeyProperties.PURPOSE_ENCRYPT or
                android.security.keystore.KeyProperties.PURPOSE_DECRYPT,
        ).setBlockModes(android.security.keystore.KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(android.security.keystore.KeyProperties.ENCRYPTION_PADDING_NONE)
            .setRandomizedEncryptionRequired(true)
            .build())
        return generator.generateKey()
    }

    private fun encryptSecret(value: String): String {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, secretKey())
        val payload = cipher.iv + cipher.doFinal(value.toByteArray(Charsets.UTF_8))
        return Base64.encodeToString(payload, Base64.NO_WRAP)
    }

    private fun decryptSecret(value: String): String {
        val payload = Base64.decode(value, Base64.NO_WRAP)
        require(payload.size > 12) { "Secreto cifrado inválido." }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, secretKey(), GCMParameterSpec(128, payload.copyOfRange(0, 12)))
        return String(cipher.doFinal(payload.copyOfRange(12, payload.size)), Charsets.UTF_8)
    }

    private external fun nativeLoadModel(path: String, contextSize: Int, threads: Int): Long
    private external fun nativeGenerate(
        handle: Long,
        roles: Array<String>,
        contents: Array<String>,
        maxTokens: Int,
        temperature: Float,
        sink: LocalTokenSink,
    )
    private external fun nativeCancel(handle: Long)
    private external fun nativeResetCancellation(handle: Long)
    private external fun nativeUnloadModel(handle: Long)

    companion object {
        init {
            System.loadLibrary("chronox_local_llm")
        }
    }

    private fun canExecuteFromData(): Boolean {
        // Ejecutar un JNI solo valida apk_data_file y da falsos positivos. Debian
        // vive bajo filesDir (app_data_file), así que probamos exactamente allí.
        val probe = File(filesDir, ".chronox-exec-probe.sh")
        return try {
            probe.writeText("#!/system/bin/sh\nexit 0\n", Charsets.UTF_8)
            if (!probe.setExecutable(true, true) || !probe.canExecute()) return false
            val process = ProcessBuilder(probe.absolutePath)
                .redirectErrorStream(true)
                .start()
            if (!process.waitFor(2, java.util.concurrent.TimeUnit.SECONDS)) {
                process.destroyForcibly()
                false
            } else {
                process.exitValue() == 0
            }
        } catch (_: Exception) {
            false
        } finally {
            probe.delete()
        }
    }
}

internal class LocalTokenSink(
    private val send: (String) -> Unit,
    private val sendMetrics: (Int, Long) -> Unit,
) {
    fun onToken(text: String) = send(text)
    fun onMetrics(tokens: Int, elapsedMs: Long) = sendMetrics(tokens, elapsedMs)
}
