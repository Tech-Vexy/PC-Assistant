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
 * On-device continuous Hotword and Voice Command Detector for Android,
 * providing Google Hotword-like wakefulness ("Hey Assistant", "OK Google", etc.)
 * with zero cloud dependencies and immediate follow-up command extraction.
 */
class HotwordDetector(
    private val context: Context,
    private val onHotwordTriggered: (hotword: String, command: String?) -> Unit
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
    private var lastTriggerTimestamp: Long = 0

    fun updateHotwords(hotwords: List<String>) {
        activeHotwords = if (hotwords.isNotEmpty()) {
            hotwords.map { it.trim().lowercase() }
        } else {
            DEFAULT_HOTWORDS
        }
    }

    fun isListening(): Boolean = isListening

    fun startListening() {
        mainHandler.post {
            if (isListening) return@post
            isListening = true
            initAndStartRecognizer()
        }
    }

    fun stopListening() {
        mainHandler.post {
            isListening = false
            destroyRecognizer()
        }
    }

    private fun initAndStartRecognizer() {
        if (!SpeechRecognizer.isRecognitionAvailable(context)) {
            return
        }

        destroyRecognizer()

        // Use on-device offline recognition when available (Android 12+ API 31+)
        speechRecognizer = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
            SpeechRecognizer.isOnDeviceRecognitionAvailable(context)) {
            SpeechRecognizer.createOnDeviceSpeechRecognizer(context)
        } else {
            SpeechRecognizer.createSpeechRecognizer(context)
        }

        speechRecognizer?.setRecognitionListener(object : RecognitionListener {
            override fun onReadyForSpeech(params: Bundle?) {
                isRecognitionActive = true
            }

            override fun onBeginningOfSpeech() {}
            override fun onRmsChanged(rmsdB: Float) {}
            override fun onBufferReceived(buffer: ByteArray?) {}

            override fun onEndOfSpeech() {
                isRecognitionActive = false
            }

            override fun onError(error: Int) {
                isRecognitionActive = false
                // Schedule restart on error if continuous hotword listening is active
                if (isListening) {
                    mainHandler.postDelayed({
                        if (isListening) {
                            beginListeningSession()
                        }
                    }, 400)
                }
            }

            override fun onResults(results: Bundle?) {
                isRecognitionActive = false
                processMatches(results)
                if (isListening) {
                    mainHandler.postDelayed({
                        if (isListening) {
                            beginListeningSession()
                        }
                    }, 300)
                }
            }

            override fun onPartialResults(partialResults: Bundle?) {
                processMatches(partialResults)
            }

            override fun onEvent(eventType: Int, params: Bundle?) {}
        })

        beginListeningSession()
    }

    private fun beginListeningSession() {
        if (!isListening || speechRecognizer == null) return

        try {
            val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
                putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
                putExtra(RecognizerIntent.EXTRA_LANGUAGE, Locale.getDefault().toString())
                putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
                putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 3)
                putExtra(RecognizerIntent.EXTRA_CALLING_PACKAGE, context.packageName)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, true)
                }
            }
            speechRecognizer?.startListening(intent)
        } catch (_: Exception) {
            // Restart after debounce if startup fails
            mainHandler.postDelayed({
                if (isListening) beginListeningSession()
            }, 600)
        }
    }

    private fun processMatches(bundle: Bundle?) {
        if (bundle == null) return
        val matches = bundle.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION) ?: return

        val now = System.currentTimeMillis()
        if (now - lastTriggerTimestamp < 2000) {
            return // 2-second debounce to avoid duplicate triggers
        }

        for (rawMatch in matches) {
            val lower = rawMatch.trim().lowercase()

            for (hw in activeHotwords) {
                if (hw == "*" || hw.isEmpty()) {
                    lastTriggerTimestamp = now
                    onHotwordTriggered("stt", rawMatch.trim())
                    return
                }

                if (lower.startsWith(hw) || lower.contains(hw)) {
                    lastTriggerTimestamp = now

                    // Extract subsequent voice command (e.g. "hey assistant open chrome" -> "open chrome")
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
