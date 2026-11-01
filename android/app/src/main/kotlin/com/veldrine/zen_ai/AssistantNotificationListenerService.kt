package com.veldrine.zen_ai

import android.app.Notification
import android.app.PendingIntent
import android.app.RemoteInput
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.provider.Settings
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.text.TextUtils
import androidx.core.app.NotificationManagerCompat
import java.util.concurrent.ConcurrentHashMap

data class CachedNotification(
    val key: String,
    val id: Int,
    val packageName: String,
    val title: String,
    val text: String,
    val subText: String,
    val timestamp: Long,
    val canReply: Boolean
)

class AssistantNotificationListenerService : NotificationListenerService() {

    companion object {
        var instance: AssistantNotificationListenerService? = null
            private set

        private val cachedNotifications = ConcurrentHashMap<String, CachedNotification>()
        private val replyActions = ConcurrentHashMap<String, Pair<Notification.Action, RemoteInput>>()

        fun isEnabled(context: Context): Boolean {
            val enabledListeners = NotificationManagerCompat.getEnabledListenerPackages(context)
            return enabledListeners.contains(context.packageName)
        }

        fun openSettings(context: Context) {
            val intent = Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK
            }
            context.startActivity(intent)
        }

        fun getNotificationsList(): List<Map<String, Any?>> {
            return cachedNotifications.values.sortedByDescending { it.timestamp }.map {
                mapOf(
                    "key" to it.key,
                    "id" to it.id,
                    "packageName" to it.packageName,
                    "title" to it.title,
                    "text" to it.text,
                    "subText" to it.subText,
                    "timestamp" to it.timestamp,
                    "canReply" to it.canReply
                )
            }
        }

        fun reply(context: Context, key: String, replyText: String): Boolean {
            val pair = replyActions[key] ?: return false
            val action = pair.first
            val remoteInput = pair.second

            return try {
                val intent = Intent()
                val bundle = Bundle()
                bundle.putCharSequence(remoteInput.resultKey, replyText)
                RemoteInput.addResultsToIntent(arrayOf(remoteInput), intent, bundle)
                action.actionIntent.send(context, 0, intent)
                true
            } catch (e: Exception) {
                false
            }
        }
    }

    override fun onListenerConnected() {
        super.onListenerConnected()
        instance = this
        syncActiveNotifications()
    }

    override fun onListenerDisconnected() {
        super.onListenerDisconnected()
        if (instance == this) {
            instance = null
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        if (instance == this) {
            instance = null
        }
    }

    override fun onNotificationPosted(sbn: StatusBarNotification?) {
        super.onNotificationPosted(sbn)
        if (sbn == null) return
        extractAndCacheNotification(sbn)
    }

    override fun onNotificationRemoved(sbn: StatusBarNotification?) {
        super.onNotificationRemoved(sbn)
        if (sbn == null) return
        cachedNotifications.remove(sbn.key)
        replyActions.remove(sbn.key)
    }

    private fun syncActiveNotifications() {
        try {
            val currentNotifications = activeNotifications ?: return
            currentNotifications.forEach(::extractAndCacheNotification)
        } catch (_: Exception) {}
    }

    private fun extractAndCacheNotification(sbn: StatusBarNotification) {
        val notification = sbn.notification ?: return
        val extras = notification.extras ?: return

        // Skip our own persistent foreground notification
        if (sbn.packageName == packageName) return

        val title = extras.getCharSequence(Notification.EXTRA_TITLE)?.toString() ?: ""
        val text = extras.getCharSequence(Notification.EXTRA_TEXT)?.toString()
            ?: extras.getCharSequence(Notification.EXTRA_BIG_TEXT)?.toString()
            ?: ""
        val subText = extras.getCharSequence(Notification.EXTRA_SUB_TEXT)?.toString() ?: ""

        if (title.isBlank() && text.isBlank()) return

        // Scan for inline RemoteInput reply action (e.g. WhatsApp, Slack, Signal, Messages, Telegram)
        var replyPair: Pair<Notification.Action, RemoteInput>? = null
        val actions = notification.actions
        if (actions != null) {
            for (action in actions) {
                val remoteInputs = action.remoteInputs
                if (remoteInputs != null && remoteInputs.isNotEmpty()) {
                    for (ri in remoteInputs) {
                        if (ri.allowFreeFormInput) {
                            replyPair = Pair(action, ri)
                            break
                        }
                    }
                }
                if (replyPair != null) break
            }
        }

        if (replyPair != null) {
            replyActions[sbn.key] = replyPair
        }

        val cached = CachedNotification(
            key = sbn.key,
            id = sbn.id,
            packageName = sbn.packageName,
            title = title,
            text = text,
            subText = subText,
            timestamp = sbn.postTime,
            canReply = replyPair != null
        )

        cachedNotifications[sbn.key] = cached
    }
}
