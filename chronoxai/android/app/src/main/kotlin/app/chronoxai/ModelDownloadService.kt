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

/** Keeps a user-started GGUF transfer alive while the activity is in background. */
class ModelDownloadService : Service() {
    companion object {
        private const val CHANNEL_ID = "model_downloads"
        private const val NOTIFICATION_ID = 4207
        private const val ACTION_START = "app.chronoxai.model_download.START"
        private const val ACTION_PROGRESS = "app.chronoxai.model_download.PROGRESS"
        private const val ACTION_FINISHED = "app.chronoxai.model_download.FINISHED"
        private const val ACTION_FAILED = "app.chronoxai.model_download.FAILED"
        private const val ACTION_STOP = "app.chronoxai.model_download.STOP"
        private const val EXTRA_TITLE = "title"
        private const val EXTRA_MESSAGE = "message"
        private const val EXTRA_RECEIVED = "received"
        private const val EXTRA_TOTAL = "total"

        fun start(context: Context, title: String) = send(context, ACTION_START) {
            putExtra(EXTRA_TITLE, title)
        }

        fun progress(context: Context, title: String, received: Long, total: Long) =
            send(context, ACTION_PROGRESS) {
                putExtra(EXTRA_TITLE, title)
                putExtra(EXTRA_RECEIVED, received)
                putExtra(EXTRA_TOTAL, total)
            }

        fun finish(context: Context, title: String, message: String) =
            send(context, ACTION_FINISHED) {
                putExtra(EXTRA_TITLE, title)
                putExtra(EXTRA_MESSAGE, message)
            }

        fun fail(context: Context, title: String, message: String) =
            send(context, ACTION_FAILED) {
                putExtra(EXTRA_TITLE, title)
                putExtra(EXTRA_MESSAGE, message)
            }

        fun stop(context: Context) = send(context, ACTION_STOP)

        private fun send(context: Context, action: String, extras: Intent.() -> Unit = {}) {
            val intent = Intent(context, ModelDownloadService::class.java).apply {
                this.action = action
                extras()
            }
            if (action == ACTION_START && Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }
    }

    private var wakeLock: PowerManager.WakeLock? = null
    private var title = "Descargando modelo"

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> {
                title = intent.getStringExtra(EXTRA_TITLE) ?: title
                startForegroundCompat(buildProgressNotification(title, 0, 0))
                acquireWakeLock()
            }
            ACTION_PROGRESS -> {
                title = intent.getStringExtra(EXTRA_TITLE) ?: title
                val received = intent.getLongExtra(EXTRA_RECEIVED, 0L)
                val total = intent.getLongExtra(EXTRA_TOTAL, 0L)
                // Updating the ongoing foreground notification is safe even when
                // the activity has left the screen.
                startForegroundCompat(buildProgressNotification(title, received, total))
            }
            ACTION_FINISHED, ACTION_FAILED -> {
                val succeeded = intent.action == ACTION_FINISHED
                val resultTitle = intent.getStringExtra(EXTRA_TITLE) ?: "ChronoxAI"
                val message = intent.getStringExtra(EXTRA_MESSAGE) ?: ""
                postResultNotification(resultTitle, message, succeeded)
                releaseWakeLock()
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf(startId)
                return START_NOT_STICKY
            }
            ACTION_STOP -> {
                releaseWakeLock()
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf(startId)
                return START_NOT_STICKY
            }
            else -> {
                stopSelf(startId)
                return START_NOT_STICKY
            }
        }
        return START_NOT_STICKY
    }

    private fun startForegroundCompat(notification: Notification) {
        createChannel()
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
        if (manager.getNotificationChannel(CHANNEL_ID) == null) {
            manager.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID,
                    "Descargas de modelos",
                    NotificationManager.IMPORTANCE_LOW,
                ).apply {
                    description = "Progreso de descargas de modelos locales"
                    setShowBadge(false)
                },
            )
        }
    }

    private fun contentIntent(): PendingIntent? {
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName) ?: return null
        return PendingIntent.getActivity(
            this,
            NOTIFICATION_ID,
            launchIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    private fun buildProgressNotification(
        title: String,
        received: Long,
        total: Long,
    ): Notification {
        val determinate = total > 0L
        val percent = if (determinate) {
            ((received * 100L / total).coerceIn(0L, 100L)).toInt()
        } else 0
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        builder
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setContentTitle(title)
            .setContentText(
                if (determinate) "$percent% · ${received / 1_000_000} / ${total / 1_000_000} MB"
                else "Preparando descarga…",
            )
            .setProgress(100, percent, !determinate)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setAutoCancel(false)
        contentIntent()?.let(builder::setContentIntent)
        return builder.build()
    }

    private fun postResultNotification(title: String, message: String, succeeded: Boolean) {
        createChannel()
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        builder
            .setSmallIcon(
                if (succeeded) android.R.drawable.stat_sys_download_done
                else android.R.drawable.stat_notify_error,
            )
            .setContentTitle(title)
            .setContentText(message)
            .setOngoing(false)
            .setAutoCancel(true)
            .setOnlyAlertOnce(true)
        contentIntent()?.let(builder::setContentIntent)
        (getSystemService(NOTIFICATION_SERVICE) as NotificationManager)
            .notify(NOTIFICATION_ID, builder.build())
    }

    private fun acquireWakeLock() {
        if (wakeLock?.isHeld == true) return
        val powerManager = getSystemService(Context.POWER_SERVICE) as? PowerManager ?: return
        wakeLock = powerManager.newWakeLock(
            PowerManager.PARTIAL_WAKE_LOCK,
            "chronoxai:model-download",
        ).apply {
            setReferenceCounted(false)
            acquire(6 * 60 * 60 * 1000L)
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
