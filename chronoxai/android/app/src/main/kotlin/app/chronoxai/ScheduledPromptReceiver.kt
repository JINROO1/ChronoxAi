package app.chronoxai

import android.app.AlarmManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.core.app.NotificationCompat

class ScheduledPromptReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val id = intent.getStringExtra(EXTRA_ID) ?: return
        val prompt = intent.getStringExtra(EXTRA_PROMPT) ?: return
        val launch = Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP
            putExtra(EXTRA_PROMPT, prompt)
        }
        val contentIntent = PendingIntent.getActivity(
            context, id.hashCode(), launch,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.createNotificationChannel(NotificationChannel(CHANNEL_ID, "Tareas programadas", NotificationManager.IMPORTANCE_DEFAULT))
        }
        manager.notify(id.hashCode(), NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_popup_reminder)
            .setContentTitle("Chronox AI")
            .setContentText(prompt.take(120))
            .setAutoCancel(true)
            .setContentIntent(contentIntent)
            .build())

        val repeatDays = intent.getIntExtra(EXTRA_REPEAT_DAYS, 0)
        if (repeatDays > 0) {
            val next = System.currentTimeMillis() + repeatDays * AlarmManager.INTERVAL_DAY
            val nextIntent = Intent(context, ScheduledPromptReceiver::class.java).apply {
                putExtra(EXTRA_ID, id)
                putExtra(EXTRA_PROMPT, prompt)
                putExtra(EXTRA_REPEAT_DAYS, repeatDays)
            }
            val pending = PendingIntent.getBroadcast(context, id.hashCode(), nextIntent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
            (context.getSystemService(Context.ALARM_SERVICE) as AlarmManager).setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, next, pending)
        }
    }

    companion object {
        const val CHANNEL_ID = "chronox_scheduled_tasks"
        const val EXTRA_ID = "chronox.task.id"
        const val EXTRA_PROMPT = "chronox.task.prompt"
        const val EXTRA_REPEAT_DAYS = "chronox.task.repeatDays"
    }
}
