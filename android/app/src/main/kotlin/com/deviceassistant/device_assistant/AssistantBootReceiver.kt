package com.deviceassistant.device_assistant

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build

/**
 * BroadcastReceiver triggered when the Android device finishes booting.
 * Restarts the AssistantForegroundService to restore the top tray notification,
 * Quick Settings tile readiness, and always-on voice awareness.
 */
class AssistantBootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val receivedAction = intent.action
        if (receivedAction == Intent.ACTION_BOOT_COMPLETED ||
            receivedAction == "android.intent.action.QUICKBOOT_POWERON" ||
            receivedAction == "com.htc.intent.action.QUICKBOOT_POWERON") {
            val serviceIntent = Intent(context, AssistantForegroundService::class.java).apply {
                action = AssistantForegroundService.ACTION_START
            }
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(serviceIntent)
                } else {
                    context.startService(serviceIntent)
                }
            } catch (_: Exception) {}
        }
    }
}
