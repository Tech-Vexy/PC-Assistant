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
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.service.quicksettings.TileService
import androidx.core.app.NotificationCompat
import io.flutter.plugin.common.MethodChannel
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

        /** Interval between speaker-drain checks while Live audio is playing. */
        private const val DRAIN_POLL_MS = 150L

        /** Silence on both the write path and the playback head that means "utterance finished". */
        private const val DRAIN_QUIET_MS = 300L

        /**
         * Registered by MainActivity so the foreground service can deliver hotword
         * results back to Flutter even when the activity is in the background.
         */
        var methodChannel: MethodChannel? = null
    }

    private var wakeLock: PowerManager.WakeLock? = null
    private var audioTrack: AudioTrack? = null
    private val audioExecutor = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())

    // Gemini Live speaker output gating for the STT microphone: while the
    // assistant is audible, continuous recognition would transcribe its own
    // voice and feed it back as a user command.
    @Volatile private var isLivePlaybackActive = false
    @Volatile private var lastChunkWriteAt = 0L
    @Volatile private var lastHeadPosition = 0L

    // On-device hotword/STT detector owned by the service so it survives
    // when MainActivity is not in the foreground.
    private var hotwordDetector: HotwordDetector? = null

    /** Returns the service-owned HotwordDetector so MainActivity can share it. */
    fun getHotwordDetector(): HotwordDetector? = hotwordDetector

    /**
     * Toggles microphone listening on/off directly from the foreground service.
     * Called by the accessibility button and notification action — never opens the app.
     */
    fun toggleListening() {
        val detector = hotwordDetector ?: return
        if (detector.isListening()) {
            detector.stopListening()
            isVoiceActive = false
            updateNotification()
            // Notify Flutter bridge if active (MainActivity in foreground)
            onTrayActionListener?.invoke("toggle_voice")
        } else {
            if (checkSelfPermission(android.Manifest.permission.RECORD_AUDIO)
                    != android.content.pm.PackageManager.PERMISSION_GRANTED) {
                // Can't request runtime permissions from a service — rely on
                // MainActivity having pre-requested permission already.
                return
            }
            detector.updateHotwords(listOf("*"))
            detector.startListening()
            isVoiceActive = true
            updateNotification()
            onTrayActionListener?.invoke("toggle_voice")
        }
    }

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
                beginLivePlayback()
                audioTrack?.write(data, 0, data.size)
            } catch (_: Exception) {}
        }
    }

    fun flushAudio() {
        endLivePlayback()
        audioExecutor.execute {
            try {
                audioTrack?.pause()
                audioTrack?.flush()
                audioTrack?.play()
            } catch (_: Exception) {}
        }
    }

    /**
     * Mutes the microphone while assistant audio is audible. Called per chunk, so
     * only the first frame of an utterance does any real work.
     */
    private fun beginLivePlayback() {
        lastChunkWriteAt = System.currentTimeMillis()
        if (isLivePlaybackActive) return

        isLivePlaybackActive = true
        lastHeadPosition = audioTrack?.playbackHeadPosition?.toLong() ?: 0L
        // Wake-word mode stays listening so the user can interrupt; free-form STT
        // would otherwise transcribe the assistant and submit its own words as a command.
        val detector = hotwordDetector
        if (detector != null && detector.isFreeFormStt()) detector.pauseListening()
        mainHandler.removeCallbacks(drainWatcher)
        mainHandler.postDelayed(drainWatcher, DRAIN_POLL_MS)
    }

    private fun endLivePlayback() {
        if (!isLivePlaybackActive) return
        isLivePlaybackActive = false
        mainHandler.removeCallbacks(drainWatcher)
        val detector = hotwordDetector ?: return
        if (detector.isPaused()) detector.resumeListening()
    }

    private val drainWatcher = object : Runnable {
        override fun run() {
            if (!isLivePlaybackActive) return

            val head = try {
                audioTrack?.playbackHeadPosition?.toLong() ?: 0L
            } catch (_: Exception) {
                0L
            }
            // Negative delta means the head wrapped around; treat it as motion for one poll.
            val advanced = head - lastHeadPosition
            lastHeadPosition = head

            val drained = advanced <= 0L &&
                System.currentTimeMillis() - lastChunkWriteAt > DRAIN_QUIET_MS

            if (drained) {
                endLivePlayback()
            } else {
                mainHandler.postDelayed(this, DRAIN_POLL_MS)
            }
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

        // Create the on-device hotword/STT detector for background operation.
        // Callbacks deliver results to Flutter via the static methodChannel reference
        // set by MainActivity, or via onTrayActionListener when the activity is alive.
        hotwordDetector = HotwordDetector(
            context = this,
            onHotwordTriggered = { hotword, command ->
                android.os.Handler(android.os.Looper.getMainLooper()).post {
                    methodChannel?.invokeMethod(
                        "onHotwordDetected",
                        mapOf("hotword" to hotword, "command" to command)
                    )
                }
            },
            onRmsChangedListener = { rms ->
                android.os.Handler(android.os.Looper.getMainLooper()).post {
                    methodChannel?.invokeMethod(
                        "onAudioRmsChanged",
                        mapOf("rms" to rms.toDouble())
                    )
                }
            },
            onPartialTranscriptListener = { partial ->
                android.os.Handler(android.os.Looper.getMainLooper()).post {
                    methodChannel?.invokeMethod(
                        "onPartialTranscript",
                        mapOf("text" to partial)
                    )
                }
            }
        )
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                onTrayActionListener?.invoke("exit")
                stopForegroundService()
            }
            ACTION_TOGGLE_VOICE -> {
                // Toggle the mic directly in the service — no activity needed.
                toggleListening()
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
        isLivePlaybackActive = false
        mainHandler.removeCallbacks(drainWatcher)
        try {
            audioTrack?.stop()
            audioTrack?.release()
            audioTrack = null
        } catch (_: Exception) {}
        try {
            audioExecutor.shutdown()
        } catch (_: Exception) {}
        try {
            hotwordDetector?.stopListening()
            hotwordDetector = null
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
