package app.chronoxai

import android.os.Handler
import android.os.Looper
import java.io.IOException
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Una sesión de terminal: proceso, tubería de entrada y lectura de salida.
 *
 * Detalles que importan y no son obvios:
 *
 *  * **El orden de cierre.** Cerrar el lector antes que el proceso deja al
 *    invitado sin stdin y puede bloquearlo esperando; cerrar el proceso antes
 *    deja el hilo lector atascado en `read()`. Aquí se destruye el proceso con
 *    sus descendientes primero (`destroy` mata el grupo, y proot arranca con
 *    `--kill-on-exit`) y después se interrumpe el lector.
 *
 *  * **Todo en un hilo aparte.** `read(stdout)` bloquea indefinidamente; en el
 *    hilo principal la app se congelaría.
 *
 *  * **Los bytes no se convierten a texto.** Un terminal recibe secuencias ANSI
 *    y bytes a medio carácter UTF-8 entre dos llamadas. Pasar a `String` aquí
 *    rompería la pantalla; la decodificación va en la capa de pantalla, que
 *    mantiene el estado.
 *
 *  * **El proceso sigue vivo aunque la actividad muera**, porque el servicio en
 *    primer plano ([TerminalService]) mantiene el proceso de la app.
 */
class PtySession(
    private val id: Int,
    private val onOutput: (id: Int, data: ByteArray) -> Unit,
    private val onExit: (id: Int, exitCode: Int) -> Unit,
) {
    private var process: Process? = null
    private val closed = AtomicBoolean(false)
    private val main = Handler(Looper.getMainLooper())

    @Volatile
    private var exitNotified = false

    /**
     * Arranca el proceso.
     *
     * [environment] se aplica **encima** del entorno heredado: `LD_LIBRARY_PATH`
     * y `PROOT_TMP_DIR` tienen que llegar sí o sí o proot no encuentra sus
     * librerías.
     */
    fun start(
        binary: String,
        arguments: List<String>,
        environment: Map<String, String>,
        workingDirectory: String?,
    ) {
        val builder = ProcessBuilder(listOf(binary) + arguments)
            .redirectErrorStream(true) // en un terminal, stderr es la misma pantalla

        if (!workingDirectory.isNullOrBlank()) {
            builder.directory(java.io.File(workingDirectory))
        }
        val env = builder.environment()
        env.putAll(environment)
        // Sin esto, el invitado ve el `PATH` de Android y no encuentra nada.
        env.remove("CLASSPATH")

        val started = builder.start()
        process = started
        started.outputStream.use { it.flush() }

        Thread({ readLoop(started) }, "chronox-pty-read-$id").start()

        Thread({
            val code = try {
                started.waitFor()
            } catch (t: Throwable) {
                -1
            }
            // Un proceso solo termina una vez; `destroy()` también lo hace
            // terminar, así que hay que evitar notificarlo dos veces.
            if (exitNotified) return@Thread
            exitNotified = true
            main.post { onExit(id, code) }
        }, "chronox-pty-wait-$id").start()
    }

    private fun readLoop(started: Process) {
        val buffer = ByteArray(8192)
        try {
            val input = started.inputStream
            while (!closed.get()) {
                val read = input.read(buffer)
                if (read <= 0) break
                val chunk = buffer.copyOf(read)
                main.post { onOutput(id, chunk) }
            }
        } catch (t: Throwable) {
            // El proceso murió o se cerró la tubería: es el final normal.
        }
    }

    /** Escribe en la entrada del proceso. Devuelve false si ya no hay proceso. */
    fun write(data: ByteArray): Boolean {
        val target = process ?: return false
        return try {
            target.outputStream.write(data)
            target.outputStream.flush()
            true
        } catch (t: IOException) {
            false
        }
    }

    /**
     * Cierra la sesión.
     *
     * `destroy()` sobre el proceso de Android mata al grupo entero; los hijos de
     * proot (el shell del invitado y lo que haya lanzado) van en el mismo grupo,
     * así que no quedan procesos huérfanos consumiendo batería.
     */
    fun close() {
        if (!closed.compareAndSet(false, true)) return
        val target = process
        process = null
        if (target != null) {
            try {
                target.destroy()
                if (target.isAlive) target.destroyForcibly()
            } catch (t: Throwable) {
                // Nada que hacer: el proceso ya no está.
            }
        }
    }

    val isRunning: Boolean
        get() = process?.isAlive == true && !closed.get()
}
