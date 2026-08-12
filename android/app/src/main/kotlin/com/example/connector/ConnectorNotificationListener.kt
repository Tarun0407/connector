package com.example.connector

import android.content.ComponentName
import android.os.Build
import android.app.Notification
import android.app.RemoteInput
import android.content.Intent
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
        try {
            activeNotifications?.forEach { notification ->
                onNotificationPosted(notification)
            }
        } catch (_: Exception) {}
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
        val replyAction = sbn.notification.actions?.firstOrNull { action ->
            action.remoteInputs?.any { it.allowFreeFormInput } == true
        }
        val replyCommandId = if (replyAction != null) {
            MainActivity.registerReplyAction(replyAction)
        } else {
            ""
        }
        val label = try {
            val appInfo = packageManager.getApplicationInfo(sbn.packageName, 0)
            packageManager.getApplicationLabel(appInfo).toString()
        } catch (_: Exception) {
            sbn.packageName
        }

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
                "label" to label,
                "title" to title,
                "text" to body,
                "postedAt" to sbn.postTime,
                "canReply" to (replyAction != null),
                "replyCommandId" to replyCommandId
            )
        )
    }
}

