package com.example.connector

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

class ConnectorMediaActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.getStringExtra(EXTRA_ACTION) ?: return
        val positionMs = intent.getLongExtra(EXTRA_POSITION_MS, -1L)
        if (positionMs >= 0) {
            MainActivity.sendLaptopMediaAction(
                mapOf("action" to action, "positionMs" to positionMs)
            )
        } else {
            MainActivity.sendLaptopMediaAction(mapOf("action" to action))
        }
    }

    companion object {
        const val EXTRA_ACTION = "action"
        const val EXTRA_POSITION_MS = "positionMs"
    }
}
