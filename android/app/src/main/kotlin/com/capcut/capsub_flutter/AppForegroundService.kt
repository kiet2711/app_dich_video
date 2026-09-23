package com.capcut.capsub_flutter

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import android.os.PowerManager

class AppForegroundService : Service() {

    private var wakeLock: PowerManager.WakeLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
        try {
            val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = powerManager.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "CapSub:ForegroundWakeLock").apply {
                acquire(30 * 60 * 1000L) // Giữ CPU chạy ngầm tối đa 30 phút
            }
        } catch (_: Exception) {
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val action = intent?.action
        if (action == ACTION_STOP) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                stopForeground(STOP_FOREGROUND_REMOVE)
            } else {
                @Suppress("DEPRECATION")
                stopForeground(true)
            }
            stopSelf()
            return START_NOT_STICKY
        }

        val title = intent?.getStringExtra(EXTRA_TITLE) ?: "CapSub AI Studio"
        val message = intent?.getStringExtra(EXTRA_MESSAGE) ?: "Đang xử lý..."
        val progress = intent?.getIntExtra(EXTRA_PROGRESS, 0) ?: 0
        val maxProgress = intent?.getIntExtra(EXTRA_MAX_PROGRESS, 100) ?: 100

        val notification = buildNotification(title, message, progress, maxProgress)
        if (action == ACTION_START) {
            startForeground(NOTIFICATION_ID, notification)
        } else {
            val manager = getSystemService(NotificationManager::class.java)
            manager.notify(NOTIFICATION_ID, notification)
        }

        return START_NOT_STICKY
    }

    override fun onDestroy() {
        try {
            wakeLock?.let {
                if (it.isHeld) it.release()
            }
        } catch (_: Exception) {
        }
        wakeLock = null
        super.onDestroy()
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Tiến trình chạy nền CapSub",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Duy trì tiến trình tạo phụ đề và lồng tiếng khi khóa màn hình"
            }
            val manager = getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(channel)
        }
    }

    private fun buildNotification(title: String, message: String, progress: Int, maxProgress: Int): Notification {
        val launchIntent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val pendingIntent = PendingIntent.getActivity(
            this,
            0,
            launchIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }

        val isIndeterminate = progress <= 0 && maxProgress <= 0
        return builder
            .setContentTitle(title)
            .setContentText(message)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setProgress(maxProgress, progress.coerceIn(0, maxProgress), isIndeterminate)
            .setContentIntent(pendingIntent)
            .setOngoing(true)
            .build()
    }

    companion object {
        const val CHANNEL_ID = "capsub_foreground_channel"
        const val NOTIFICATION_ID = 42018

        const val ACTION_START = "com.capcut.capsub.ACTION_START"
        const val ACTION_UPDATE = "com.capcut.capsub.ACTION_UPDATE"
        const val ACTION_STOP = "com.capcut.capsub.ACTION_STOP"

        const val EXTRA_TITLE = "extra_title"
        const val EXTRA_MESSAGE = "extra_message"
        const val EXTRA_PROGRESS = "extra_progress"
        const val EXTRA_MAX_PROGRESS = "extra_max_progress"

        fun start(context: Context, title: String, message: String, progress: Int, maxProgress: Int) {
            val intent = Intent(context, AppForegroundService::class.java).apply {
                action = ACTION_START
                putExtra(EXTRA_TITLE, title)
                putExtra(EXTRA_MESSAGE, message)
                putExtra(EXTRA_PROGRESS, progress)
                putExtra(EXTRA_MAX_PROGRESS, maxProgress)
            }
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
            } catch (_: Exception) {
            }
        }

        fun update(context: Context, title: String?, message: String, progress: Int, maxProgress: Int) {
            val intent = Intent(context, AppForegroundService::class.java).apply {
                action = ACTION_UPDATE
                if (title != null) putExtra(EXTRA_TITLE, title)
                putExtra(EXTRA_MESSAGE, message)
                putExtra(EXTRA_PROGRESS, progress)
                putExtra(EXTRA_MAX_PROGRESS, maxProgress)
            }
            try {
                context.startService(intent)
            } catch (_: Exception) {
            }
        }

        fun stop(context: Context) {
            val intent = Intent(context, AppForegroundService::class.java).apply {
                action = ACTION_STOP
            }
            try {
                context.startService(intent)
            } catch (_: Exception) {
            }
        }
    }
}
