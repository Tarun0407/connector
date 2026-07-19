package com.example.connector

import android.content.ComponentName
import android.os.Build
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification

class ConnectorNotificationListener : NotificationListenerService() {
    private val lastNotifications = mutableMapOf<String, String>()

    override fun onListenerConnected() {
        super.onListenerConnected()
        MainActivity.sendPhoneNotification(
            mapOf(
                "package" to packageName,
                "title" to "Connector",
                "text" to "Notification mirroring connected",
                "postedAt" to System.currentTimeMillis(),
                "system" to true
            )
        )
    }

    override fun onListenerDisconnected() {
        super.onListenerDisconnected()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            requestRebind(ComponentName(this, ConnectorNotificationListener::class.java))
        }
    }

    override fun onNotificationPosted(sbn: StatusBarNotification) {
        if (sbn.packageName == packageName) {
            return
        }

        val extras = sbn.notification.extras
        val title = extras.getCharSequence("android.title")?.toString().orEmpty()
        val text = extras.getCharSequence("android.text")?.toString().orEmpty()
        val bigText = extras.getCharSequence("android.bigText")?.toString()
        val summary = extras.getCharSequence("android.summaryText")?.toString()
        val body = bigText ?: text.ifBlank { summary.orEmpty() }

        // Create a unique key for this notification content
        val notificationKey = "${sbn.packageName}_${title}_${body}"

        // Only send if the content has actually changed since the last time we saw it
        if (lastNotifications[sbn.packageName] == notificationKey) {
            return
        }

        lastNotifications[sbn.packageName] = notificationKey

        MainActivity.sendPhoneNotification(
            mapOf(
                "package" to sbn.packageName,
                "title" to title,
                "text" to body,
                "postedAt" to sbn.postTime
            )
        )
    }
}

