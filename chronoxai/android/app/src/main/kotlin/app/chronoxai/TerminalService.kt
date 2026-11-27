package app.chronoxai

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager

/**
 * Servicio en primer plano que mantiene viva la sesión de shell.
 *
 * Sin esto, Android congela el proceso de la app al pasar a segundo plano y
 * `proot` muere con él: cualquier `apt install` largo o un entrenamiento de diez
 * minutos se pierde. El servicio no ejecuta comandos por su cuenta; solo declara
 * "hay trabajo en curso" para que el sistema no congele el proceso.
 *
 * Detalles que cambian según la versión (y que son fuente de crashes si se
 * ignoran):
 *
 *  - **API 34+**: hay que declarar el *tipo* al arrancar
 *    (`FOREGROUND_SERVICE_TYPE_DATA_SYNC`) o el sistema lanza
 *    `MissingForegroundServiceTypeException`.
 *  - **API 33+**: publicar la notificación requiere `POST_NOTIFICATIONS` en
 *    tiempo de ejecución; si no se concede, el servicio puede arrancar igual,
 *    pero no se verá.
 *  - **API 31+**: no se puede arrancar un servicio en primer plano desde segundo
 *    plano (`ForegroundServiceStartNotAllowedException`). Por eso se arranca
 *    siempre desde la actividad visible.
 *  - **API 35**: las apps en segundo plano se congelan antes; el wake lock con
 *    `PARTIAL_WAKE_LOCK` es lo que mantiene la CPU despierta con la pantalla
 *    apagada.
 */
class TerminalService : Service() {

    companion object {
        const val CHANNEL_ID = "chronox_terminal"
        const val NOTIFICATION_ID = 1001

        const val ACTION_START = "app.chronoxai.action.START"
        const val ACTION_STOP = "app.chronoxai.action.STOP"
        const val EXTRA_TITLE = "title"

        fun start(context: Context, title: String = "Sesión activa") {
            val intent = Intent(context, TerminalService::class.java).apply {
                action = ACTION_START
                putExtra(EXTRA_TITLE, title)
            }
            context.startService(intent)
        }

        fun stop(context: Context) {
            context.startService(
                Intent(context, TerminalService::class.java).apply {
                    action = ACTION_STOP
                },
            )
        }
    }

    private var wakeLock: PowerManager.WakeLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                releaseWakeLock()
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
                return START_NOT_STICKY
            }

            else -> {
                val title = intent?.getStringExtra(EXTRA_TITLE) ?: "Sesión activa"
                startForegroundCompat(title)
                acquireWakeLock()
            }
        }

        // Si el sistema mata el servicio, no se reintenta solo: reanudar un
        // proceso hijo que ya no existe solo reproduce el fallo.
        return START_NOT_STICKY
    }

    private fun startForegroundCompat(title: String) {
        createChannel()
        val notification = buildNotification(title)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java) ?: return
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return

        val channel = NotificationChannel(
            CHANNEL_ID,
            "Terminal y tareas en curso",
            // IMPORTANCE_LOW: sin sonido ni cabecera. Un servicio permanente que
            // suena cada vez que se ejecuta un comando acaba silenciado por el
            // usuario, que es peor que una notificación discreta.
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "Mantiene vivos los comandos y la sesión del agente."
            setShowBadge(false)
        }
        manager.createNotificationChannel(channel)
    }

    private fun buildNotification(title: String): Notification {
        val openApp = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        } else {
            PendingIntent.FLAG_UPDATE_CURRENT
        }
        val contentIntent = PendingIntent.getActivity(this, 0, openApp, flags)

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            Notification.Builder(this)
        }

        return builder
            .setContentTitle(title)
            .setContentText("Chronox AI mantiene el contenedor Linux en marcha.")
            .setSmallIcon(android.R.drawable.stat_sys_download_done)
            .setContentIntent(contentIntent)
            .setOngoing(true)
            .setPriority(Notification.PRIORITY_LOW)
            .build()
    }

    private fun acquireWakeLock() {
        if (wakeLock?.isHeld == true) return
        val power = getSystemService(Context.POWER_SERVICE) as? PowerManager ?: return
        wakeLock = power
            .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "chronoxai:terminal")
            .apply {
                setReferenceCounted(false)
                acquire(60 * 60 * 1000L)
            }
    }

    private fun releaseWakeLock() {
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
    }

    override fun onDestroy() {
        releaseWakeLock()
        super.onDestroy()
    }
}
