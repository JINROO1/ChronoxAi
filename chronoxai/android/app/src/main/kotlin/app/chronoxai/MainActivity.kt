package app.chronoxai

import android.os.Build
import android.system.Os
import android.system.OsConstants
import androidx.annotation.NonNull
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Actividad principal.
 *
 * No ejecuta ningún proceso: todo el trabajo de proot se hace desde Dart con
 * `Process.start`. Aquí solo se exponen los datos del dispositivo que Dart no
 * puede leer de forma fiable, y que deciden si el runtime Linux puede funcionar:
 *
 *  - `nativeLibraryDir`: único directorio con permiso de ejecución garantizado
 *    (`apk_data_file`) aunque el `targetSdk` sea >= 29. Aquí viven
 *    `libproot.so`, `libtalloc.so` y `libandroid-shmem.so`.
 *  - `pageSize`: en Android 15+ puede ser 16384, lo que rompe binarios ELF
 *    alineados a 4 KB.
 *  - estado de SELinux: algunos fabricantes lo endurecen y ni `targetSdk 28`
 *    permite ejecutar binarios descargados.
 */
class MainActivity : FlutterActivity() {

    private val channelName = "app.chronoxai/platform"

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            channelName,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "facts" -> result.success(platformFacts())
                else -> result.notImplemented()
            }
        }
    }

    private fun platformFacts(): Map<String, Any?> {
        return mapOf(
            "sdkInt" to Build.VERSION.SDK_INT,
            "abi" to Build.SUPPORTED_ABIS.firstOrNull(),
            "pageSize" to pageSize(),
            "nativeLibraryDir" to applicationInfo.nativeLibraryDir,
            "filesDir" to filesDir.absolutePath,
            "cacheDir" to cacheDir.absolutePath,
            "selinuxEnforcing" to isSelinuxEnforcing(),
            "targetSdk" to applicationInfo.targetSdkVersion,
        )
    }

    /**
     * Tamaño de página real del kernel. `sysconf` es la vía correcta: leer
     * /proc/self/pagemap requiere permisos que no tenemos.
     */
    private fun pageSize(): Long {
        return try {
            Os.sysconf(OsConstants._SC_PAGESIZE)
        } catch (t: Throwable) {
            4096L
        }
    }

    /**
     * `getenforce` no es invocable desde una app sin root, pero `/sys/fs/selinux/enforce`
     * sí es legible en la mayoría de dispositivos. Si no se puede leer asumimos
     * enforcing, que es lo seguro.
     */
    private fun isSelinuxEnforcing(): Boolean {
        val enforceFile = File("/sys/fs/selinux/enforce")
        return try {
            if (enforceFile.exists() && enforceFile.canRead()) {
                enforceFile.readText().trim() == "1"
            } else {
                Build.VERSION.SDK_INT >= Build.VERSION_CODES.JELLY_BEAN_MR2
            }
        } catch (t: Throwable) {
            true
        }
    }
}
