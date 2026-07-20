package com.example.connector

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder

class ConnectorForegroundService : Service() {
    private var currentTitle = "Connector is running"
    private var currentText = "Remote pairing stays available after restart."

    override fun onCreate() {
        super.onCreate()
        createChannel()
        startForeground(NOTIFICATION_ID, buildNotification())
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            @Suppress("DEPRECATION")
            stopForeground(true)
            stopSelf()
            android.os.Process.killProcess(android.os.Process.myPid())
            return START_NOT_STICKY
        }
        intent?.getStringExtra(EXTRA_TITLE)?.let { currentTitle = it }
        intent?.getStringExtra(EXTRA_TEXT)?.let { currentText = it }
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.notify(NOTIFICATION_ID, buildNotification())
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun buildNotification(): Notification {
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
        val pendingIntent = PendingIntent.getActivity(
            this,
            0,
            launchIntent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }

        val stopIntent = Intent(this, ConnectorForegroundService::class.java)
        stopIntent.action = ACTION_STOP
        val stopPendingIntent = PendingIntent.getService(
            this,
            1,
            stopIntent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        builder.addAction(android.R.drawable.ic_menu_close_clear_cancel, "Exit", stopPendingIntent)

        return builder
            .setSmallIcon(applicationInfo.icon)
            .setContentTitle(currentTitle)
            .setContentText(currentText)
            .setContentIntent(pendingIntent)
            .setOngoing(true)
            .build()
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val channel = NotificationChannel(
            CHANNEL_ID,
            "Connector background",
            NotificationManager.IMPORTANCE_LOW
        )
        manager.createNotificationChannel(channel)
    }

    companion object {
        private const val CHANNEL_ID = "connector_background"
        private const val NOTIFICATION_ID = 1208
        private const val ACTION_STOP = "com.example.connector.STOP_FOREGROUND"
        private const val EXTRA_TITLE = "title"
        private const val EXTRA_TEXT = "text"

        fun updateStatus(context: Context, title: String, text: String) {
            val intent = Intent(context, ConnectorForegroundService::class.java).apply {
                putExtra(EXTRA_TITLE, title)
                putExtra(EXTRA_TEXT, text)
            }
            context.startService(intent)
        }
    }
}
