package com.deviceassistant.device_assistant

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.service.quicksettings.TileService
import androidx.core.app.NotificationCompat
import java.util.concurrent.Executors

/**
 * Always-on Foreground Service acting as the Android equivalent of the
 * Windows/Linux System Tray. Provides persistent status bar awareness,
 * quick action buttons (Toggle Voice, Open, Exit), and maintains process immunity.
 */
class AssistantForegroundService : Service() {

    companion object {
        const val CHANNEL_ID = "device_assistant_tray_foreground"
        const val NOTIFICATION_ID = 1001

        const val ACTION_START = "ACTION_START"
        const val ACTION_STOP = "ACTION_STOP"
        const val ACTION_TOGGLE_VOICE = "ACTION_TOGGLE_VOICE"
        const val ACTION_UPDATE_STATUS = "ACTION_UPDATE_STATUS"

        const val EXTRA_IS_ACTIVE = "EXTRA_IS_ACTIVE"
        const val EXTRA_STATUS_TEXT = "EXTRA_STATUS_TEXT"

        var instance: AssistantForegroundService? = null
            private set

        var isVoiceActive: Boolean = false
            private set

        var onTrayActionListener: ((action: String) -> Unit)? = null
    }

    private var wakeLock: PowerManager.WakeLock? = null
    private var audioTrack: AudioTrack? = null
    private val audioExecutor = Executors.newSingleThreadExecutor()

    private fun initAudioTrack() {
        val sampleRate = 24000
        val minBufferSize = AudioTrack.getMinBufferSize(
            sampleRate,
            AudioFormat.CHANNEL_OUT_MONO,
            AudioFormat.ENCODING_PCM_16BIT
        )
        val bufferSize = Math.max(minBufferSize, 24000 * 2)

        val attributes = AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_ASSISTANCE_NAVIGATION_GUIDANCE)
            .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
            .build()

        val format = AudioFormat.Builder()
            .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
            .setSampleRate(sampleRate)
            .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
            .build()

        audioTrack = AudioTrack.Builder()
            .setAudioAttributes(attributes)
            .setAudioFormat(format)
            .setBufferSizeInBytes(bufferSize)
            .setTransferMode(AudioTrack.MODE_STREAM)
            .build()

        audioTrack?.play()
    }

    fun writeAudioChunk(data: ByteArray) {
        audioExecutor.execute {
            try {
                if (audioTrack == null || audioTrack?.state != AudioTrack.STATE_INITIALIZED) {
                    initAudioTrack()
                }
                audioTrack?.write(data, 0, data.size)
            } catch (_: Exception) {}
        }
    }

    fun flushAudio() {
        audioExecutor.execute {
            try {
                audioTrack?.pause()
                audioTrack?.flush()
                audioTrack?.play()
            } catch (_: Exception) {}
        }
    }

    override fun onCreate() {
        super.onCreate()
        instance = this
        createNotificationChannel()

        val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
        wakeLock = powerManager.newWakeLock(
            PowerManager.PARTIAL_WAKE_LOCK,
            "DeviceAssistant::ForegroundVoiceLock"
        ).apply {
            setReferenceCounted(false)
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                onTrayActionListener?.invoke("exit")
                stopForegroundService()
            }
            ACTION_TOGGLE_VOICE -> {
                onTrayActionListener?.invoke("toggle_voice")
            }
            ACTION_UPDATE_STATUS -> {
                isVoiceActive = intent.getBooleanExtra(EXTRA_IS_ACTIVE, isVoiceActive)
                val customStatus = intent.getStringExtra(EXTRA_STATUS_TEXT)
                updateNotification(customStatus)
            }
            else -> {
                startForegroundService()
            }
        }
        return START_STICKY
    }

    private fun startForegroundService() {
        try {
            if (wakeLock?.isHeld != true) {
                wakeLock?.acquire(24 * 60 * 60 * 1000L) // 24 hours max
            }
        } catch (_: Exception) {}

        val notification = buildTrayNotification(isVoiceActive, null)
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                val hasAudioPerm = checkSelfPermission(android.Manifest.permission.RECORD_AUDIO) ==
                    android.content.pm.PackageManager.PERMISSION_GRANTED
                if (hasAudioPerm && Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    startForeground(
                        NOTIFICATION_ID,
                        notification,
                        android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
                    )
                } else {
                    startForeground(NOTIFICATION_ID, notification)
                }
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
        } catch (_: Exception) {
            try {
                startForeground(NOTIFICATION_ID, notification)
            } catch (_: Exception) {}
        }
    }

    fun updateNotification(customStatusText: String? = null) {
        val manager = getSystemService(NotificationManager::class.java)
        val notification = buildTrayNotification(isVoiceActive, customStatusText)
        manager.notify(NOTIFICATION_ID, notification)

        // Sync Android Quick Settings Top Bar Tile
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            try {
                TileService.requestListeningState(
                    this,
                    ComponentName(this, AssistantTileService::class.java)
                )
            } catch (_: Exception) {}
        }
    }

    private fun buildTrayNotification(isActive: Boolean, statusText: String?): Notification {
        // Tap notification to open main app
        val openAppIntent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val openAppPendingIntent = PendingIntent.getActivity(
            this,
            0,
            openAppIntent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )

        // Action: Toggle Voice
        val toggleVoiceIntent = Intent(this, AssistantForegroundService::class.java).apply {
            action = ACTION_TOGGLE_VOICE
        }
        val toggleVoicePendingIntent = PendingIntent.getService(
            this,
            1,
            toggleVoiceIntent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )

        // Action: Exit Service
        val exitIntent = Intent(this, AssistantForegroundService::class.java).apply {
            action = ACTION_STOP
        }
        val exitPendingIntent = PendingIntent.getService(
            this,
            2,
            exitIntent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )

        val voiceActionTitle = if (isActive) "Pause Listening" else "Start Listening"
        val subtitle = statusText ?: if (isActive) "Gemini Live Listening (Shield Active)" else "Idle - Tap to summon voice"

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Device Assistant")
            .setContentText(subtitle)
            .setSmallIcon(android.R.drawable.ic_btn_speak_now)
            .setContentIntent(openAppPendingIntent)
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            // Tray Action Buttons:
            .addAction(
                android.R.drawable.ic_media_play,
                voiceActionTitle,
                toggleVoicePendingIntent
            )
            .addAction(
                android.R.drawable.ic_menu_close_clear_cancel,
                "Exit",
                exitPendingIntent
            )
            .build()
    }

    private fun stopForegroundService() {
        if (wakeLock?.isHeld == true) {
            wakeLock?.release()
        }
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    override fun onDestroy() {
        if (wakeLock?.isHeld == true) {
            wakeLock?.release()
        }
        try {
            audioTrack?.stop()
            audioTrack?.release()
            audioTrack = null
        } catch (_: Exception) {}
        try {
            audioExecutor.shutdown()
        } catch (_: Exception) {}
        if (instance == this) {
            instance = null
        }
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Device Assistant Top Bar & Tray",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Status bar tray controller for Gemini Live and Sensitive App Guard"
                setShowBadge(false)
            }
            val manager = getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(channel)
        }
    }
}
