package com.deviceassistant.device_assistant

import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import java.util.Locale

/**
 * Robust on-device STT and continuous Hotword Detector for Android.
 * Collects microphone audio, converts speech to text using Android SpeechRecognizer,
 * and passes the transcribed text to Flutter for LLM processing.
 */
class HotwordDetector(
    private val context: Context,
    private val onHotwordTriggered: (hotword: String, command: String?) -> Unit,
    private val onRmsChangedListener: ((rmsdB: Float) -> Unit)? = null,
    private val onPartialTranscriptListener: ((text: String) -> Unit)? = null
) {
    companion object {
        val DEFAULT_HOTWORDS = listOf(
            "hey assistant",
            "ok assistant",
            "device assistant",
            "computer",
            "jarvis",
            "hey google",
            "ok google"
        )
    }

    private val mainHandler = Handler(Looper.getMainLooper())
    private var speechRecognizer: SpeechRecognizer? = null
    private var activeHotwords: List<String> = DEFAULT_HOTWORDS
    private var isListening: Boolean = false
    private var isRecognitionActive: Boolean = false
    private var isPaused: Boolean = false
    private var lastTriggerTimestamp: Long = 0

    fun updateHotwords(hotwords: List<String>) {
        activeHotwords = if (hotwords.isNotEmpty()) {
            hotwords.map { it.trim().lowercase() }
        } else {
            DEFAULT_HOTWORDS
        }
    }

    fun isListening(): Boolean = isListening

    fun isPaused(): Boolean = isPaused

    fun pauseListening() {
        mainHandler.post {
            isPaused = true
            try {
                speechRecognizer?.stopListening()
            } catch (_: Exception) {}
            isRecognitionActive = false
        }
    }

    fun resumeListening() {
        mainHandler.post {
            isPaused = false
            if (isListening) {
                beginListeningSession()
            }
        }
    }

    fun startListening() {
        mainHandler.post {
            if (isListening && !isPaused) return@post
            if (context.checkSelfPermission(android.Manifest.permission.RECORD_AUDIO) != android.content.pm.PackageManager.PERMISSION_GRANTED) {
                return@post
            }
            isListening = true
            isPaused = false
            initAndStartRecognizer()
        }
    }

    fun stopListening() {
        mainHandler.post {
            isListening = false
            isPaused = false
            destroyRecognizer()
        }
    }

    private fun initAndStartRecognizer() {
        if (!SpeechRecognizer.isRecognitionAvailable(context)) {
            return
        }

        destroyRecognizer()

        try {
            speechRecognizer = SpeechRecognizer.createSpeechRecognizer(context)
        } catch (_: Exception) {
            return
        }

        speechRecognizer?.setRecognitionListener(object : RecognitionListener {
            override fun onReadyForSpeech(params: Bundle?) {
                isRecognitionActive = true
            }

            override fun onBeginningOfSpeech() {
                isRecognitionActive = true
            }

            override fun onRmsChanged(rmsdB: Float) {
                if (!isPaused && rmsdB > 0f) {
                    onRmsChangedListener?.invoke(rmsdB)
                }
            }

            override fun onBufferReceived(buffer: ByteArray?) {}

            override fun onEndOfSpeech() {
                isRecognitionActive = false
            }

            override fun onError(error: Int) {
                isRecognitionActive = false
                if (error == SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS) {
                    isListening = false
                    return
                }

                // If paused (e.g. during TTS playback), do not restart listening
                if (!isListening || isPaused) return

                val restartDelay = when (error) {
                    SpeechRecognizer.ERROR_RECOGNIZER_BUSY -> 600L
                    SpeechRecognizer.ERROR_NO_MATCH,
                    SpeechRecognizer.ERROR_SPEECH_TIMEOUT -> 250L
                    SpeechRecognizer.ERROR_NETWORK_TIMEOUT,
                    SpeechRecognizer.ERROR_NETWORK -> 800L
                    else -> 500L
                }

                mainHandler.postDelayed({
                    if (isListening && !isPaused) {
                        // Re-initialize recognizer if it errored out on client/server state
                        if (error == SpeechRecognizer.ERROR_CLIENT || error == SpeechRecognizer.ERROR_SERVER) {
                            initAndStartRecognizer()
                        } else {
                            beginListeningSession()
                        }
                    }
                }, restartDelay)
            }

            override fun onResults(results: Bundle?) {
                isRecognitionActive = false
                processFinalResults(results)
                if (isListening && !isPaused) {
                    mainHandler.postDelayed({
                        if (isListening && !isPaused) {
                            beginListeningSession()
                        }
                    }, 350)
                }
            }

            override fun onPartialResults(partialResults: Bundle?) {
                val matches = partialResults?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                val partial = matches?.firstOrNull()?.trim()
                if (!partial.isNullOrEmpty()) {
                    onPartialTranscriptListener?.invoke(partial)
                }
            }

            override fun onEvent(eventType: Int, params: Bundle?) {}
        })

        beginListeningSession()
    }

    private fun beginListeningSession() {
        if (!isListening || isPaused || speechRecognizer == null) return

        try {
            val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
                putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
                putExtra(RecognizerIntent.EXTRA_LANGUAGE, Locale.getDefault().toString())
                putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
                putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 3)
                putExtra(RecognizerIntent.EXTRA_CALLING_PACKAGE, context.packageName)
            }
            speechRecognizer?.startListening(intent)
        } catch (_: Exception) {
            mainHandler.postDelayed({
                if (isListening && !isPaused) beginListeningSession()
            }, 600)
        }
    }

    private fun processFinalResults(bundle: Bundle?) {
        if (bundle == null || isPaused) return
        val matches = bundle.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION) ?: return
        if (matches.isEmpty()) return

        val now = System.currentTimeMillis()
        if (now - lastTriggerTimestamp < 800) {
            return
        }

        val isSttOnly = activeHotwords.any { it == "*" || it.isEmpty() }

        if (isSttOnly) {
            val bestText = matches.firstOrNull { it.isNotBlank() }?.trim() ?: return
            lastTriggerTimestamp = now
            onHotwordTriggered("stt", bestText)
            return
        }

        // Hotword detection mode
        for (rawMatch in matches) {
            val lower = rawMatch.trim().lowercase()
            for (hw in activeHotwords) {
                if (lower.startsWith(hw) || lower.contains(hw)) {
                    lastTriggerTimestamp = now
                    val hwIndex = lower.indexOf(hw)
                    val afterHotword = lower.substring(hwIndex + hw.length).trim()
                    val command = if (afterHotword.isNotEmpty()) afterHotword else null
                    onHotwordTriggered(hw, command)
                    return
                }
            }
        }
    }

    private fun destroyRecognizer() {
        try {
            speechRecognizer?.stopListening()
            speechRecognizer?.cancel()
            speechRecognizer?.destroy()
        } catch (_: Exception) {}
        speechRecognizer = null
        isRecognitionActive = false
    }
}
