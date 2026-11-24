package app.chronoxai

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.speech.RecognizerIntent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import android.system.Os
import android.system.OsConstants
import androidx.annotation.NonNull
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.atomic.AtomicInteger

/**
 * Actividad principal.
 *
 * Los comandos del agente se lanzan desde Dart con `Process.start`. Aquí viven
 * dos cosas que Dart no puede hacer bien:
 *
 *  * los datos del dispositivo que deciden si el runtime puede funcionar;
 *  * las sesiones de terminal ([PtySession]), porque hay que quedarse con el
 *    `Process` de Kotlin para poder escribirle, matarlo con sus descendientes y
 *    avisar a Dart cuando termina.
 */
class MainActivity : FlutterActivity() {

    private val platformChannel = "app.chronoxai/platform"
    private val permissionsChannel = "app.chronoxai/permissions"
    private val ptyChannelName = "app.chronoxai/pty"
    private val schedulerChannelName = "app.chronoxai/scheduler"
    private val voiceChannelName = "app.chronoxai/voice"

    private val sessions = mutableMapOf<Int, PtySession>()
    private val nextSessionId = AtomicInteger(1)
    private var ptyChannel: MethodChannel? = null

    /** Resultado pendiente del diálogo de permisos, que es asíncrono. */
    private var pendingPermissionResult: MethodChannel.Result? = null
    private val notificationRequestCode = 4001
    private val voiceRequestCode = 4002
    private val voiceActivityRequestCode = 4003
    private var pendingVoiceResult: MethodChannel.Result? = null

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
    }

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Si el motor se recrea (cambio de configuración, recreación por el
        // sistema), las sesiones anteriores quedan sin quien las escuche. Se
        // cierran para no dejar procesos de proot huérfanos consumiendo batería.
        closeAllSessions()

        // Android 15 obliga a dibujar hasta los bordes; sin esto, en API 35 la
        // app sale con barras de sistema opacas pase lo que pase en Dart.
        if (Build.VERSION.SDK_INT >= 35) {
            window.setDecorFitsSystemWindows(false)
        }

        ptyChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            ptyChannelName,
        ).also { channel ->
            channel.setMethodCallHandler { call, result -> handlePty(call, result) }
        }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            platformChannel,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "facts" -> result.success(platformFacts())
                else -> result.notImplemented()
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
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
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

    // -----------------------------------------------------------------------
    // Sesiones de terminal
    // -----------------------------------------------------------------------

    private fun handlePty(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "start" -> {
                val binary = call.argument<String>("binary")
                val args = call.argument<List<String>>("args") ?: emptyList()
                if (binary.isNullOrBlank()) {
                    result.error("sin_binario", "No se indicó qué ejecutar.", null)
                    return
                }
                @Suppress("UNCHECKED_CAST")
                val env = call.argument<Map<String, String>>("env") ?: emptyMap()
                val cwd = call.argument<String>("cwd")
                result.success(startSession(binary, args, env, cwd))
            }
            "write" -> {
                val id = call.argument<Int>("id") ?: -1
                val data = call.argument<ByteArray>("data")
                val session = sessions[id]
                if (session == null || data == null) {
                    result.success(false)
                    return
                }
                result.success(session.write(data))
            }
            "close" -> {
                val id = call.argument<Int>("id") ?: -1
                sessions.remove(id)?.close()
                result.success(null)
            }
            "closeAll" -> {
                closeAllSessions()
                result.success(null)
            }
            "list" -> result.success(sessions.keys.map { id ->
                mapOf("id" to id, "running" to true, "command" to "Terminal")
            })
            "resize" -> {
                // Sin PTY del kernel no hay tamaño de ventana que comunicar:
                // el shell del invitado corre con el ancho por defecto. Se
                // responde éxito para que la UI no muestre un error por algo
                // que no depende de ella.
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun startSession(
        binary: String,
        args: List<String>,
        env: Map<String, String>,
        cwd: String?,
    ): Int {
        val id = nextSessionId.getAndIncrement()
        val session = PtySession(
            id = id,
            onOutput = { sessionId, data ->
                ptyChannel?.invokeMethod("output", mapOf("id" to sessionId, "data" to data))
            },
            onExit = { sessionId, code ->
                sessions.remove(sessionId)
                ptyChannel?.invokeMethod("exit", mapOf("id" to sessionId, "exitCode" to code))
            },
        )
        sessions[id] = session
        return try {
            session.start(binary, args, env, cwd)
            id
        } catch (t: Throwable) {
            sessions.remove(id)
            throw t
        }
    }

    private fun closeAllSessions() {
        val copy = sessions.values.toList()
        sessions.clear()
        copy.forEach { it.close() }
    }

    override fun onDestroy() {
        // Solo si la actividad se destruye de verdad; un cambio de orientación
        // recrea la actividad y no debe matar la sesión del usuario.
        if (isFinishing) closeAllSessions()
        super.onDestroy()
    }

    private fun platformFacts(): Map<String, Any?> {
        val context = applicationContext
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
            "canExecuteFromData" to canExecuteFromData(context, nativeLibDir),
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
    private fun canExecuteFromData(context: android.content.Context, nativeLibDir: String?): Boolean {
        if (nativeLibDir == null) return false
        val candidate = File(nativeLibDir, "libproot.so")
        if (!candidate.exists()) return false

        // 1. Que el fichero tenga el bit de ejecución en disco.
        if (!candidate.canExecute()) return false

        // 2. Que el kernel lo intente ejecutar sin denegar por SELinux.
        return try {
            val process = ProcessBuilder(candidate.absolutePath).redirectErrorStream(true).start()
            process.waitFor()
            // ENOEXEC/ELIBBAD no son un problema de permisos; EACCES sí lo sería.
            true
        } catch (t: Throwable) {
            val message = (t.message ?: "").lowercase()
            !(message.contains("permission denied") || message.contains("eacces"))
        }
    }
}
