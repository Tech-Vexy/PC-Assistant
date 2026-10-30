package com.deviceassistant.device_assistant

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import android.speech.tts.TextToSpeech
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.Locale

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.deviceassistant/bridge"
    private var methodChannel: MethodChannel? = null
    private var hotwordDetector: HotwordDetector? = null
    private var textToSpeech: TextToSpeech? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        hotwordDetector = HotwordDetector(this) { hotword, command ->
            runOnUiThread {
                methodChannel?.invokeMethod(
                    "onHotwordDetected",
                    mapOf("hotword" to hotword, "command" to command)
                )
            }
        }

        textToSpeech = TextToSpeech(this) { status ->
            if (status == TextToSpeech.SUCCESS) {
                textToSpeech?.language = Locale.getDefault()
            }
        }

        methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "isAccessibilityEnabled" -> {
                        val isEnabled = isAccessibilityServiceEnabled(context)
                        result.success(isEnabled)
                    }

                    "openAccessibilitySettings" -> {
                        val intent = Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS).apply {
                            flags = Intent.FLAG_ACTIVITY_NEW_TASK
                        }
                        startActivity(intent)
                        result.success(true)
                    }

                    "clickByText" -> {
                        val text = call.argument<String>("text") ?: ""
                        val viewId = call.argument<String>("viewId")
                        val success = AssistantAccessibilityService.instance?.clickByText(text, viewId) ?: false
                        result.success(success)
                    }

                    "updateProtectedPackages" -> {
                        val packages = call.argument<List<String>>("packages") ?: emptyList()
                        AssistantAccessibilityService.instance?.updateCustomProtectedPackages(packages)
                        result.success(true)
                    }

                    "injectTap" -> {
                        val x = (call.argument<Double>("x") ?: 0.0).toFloat()
                        val y = (call.argument<Double>("y") ?: 0.0).toFloat()
                        val dispatched = AssistantAccessibilityService.instance?.injectTap(x, y) { success ->
                            // Optional async callback
                        } ?: false
                        result.success(dispatched)
                    }

                    "injectSwipe" -> {
                        val startX = (call.argument<Double>("startX") ?: 0.0).toFloat()
                        val startY = (call.argument<Double>("startY") ?: 0.0).toFloat()
                        val endX = (call.argument<Double>("endX") ?: 0.0).toFloat()
                        val endY = (call.argument<Double>("endY") ?: 0.0).toFloat()
                        val duration = (call.argument<Int>("durationMs") ?: 300).toLong()

                        val dispatched = AssistantAccessibilityService.instance?.injectSwipe(
                            startX, startY, endX, endY, duration
                        ) ?: false
                        result.success(dispatched)
                    }

                    "performNavigation" -> {
                        val action = call.argument<Int>("action") ?: 1 // Default BACK = 1
                        val success = AssistantAccessibilityService.instance?.performNavigation(action) ?: false
                        result.success(success)
                    }

                    "dumpWindowHierarchy" -> {
                        val hierarchy = AssistantAccessibilityService.instance?.dumpWindowHierarchy() ?: emptyList<Map<String, Any>>()
                        result.success(hierarchy)
                    }

                    "getActivePackageName" -> {
                        val pkg = AssistantAccessibilityService.instance?.activePackageName
                        result.success(pkg)
                    }

                    "startForegroundService" -> {
                        val intent = Intent(this@MainActivity, AssistantForegroundService::class.java).apply {
                            action = AssistantForegroundService.ACTION_START
                        }
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            startForegroundService(intent)
                        } else {
                            startService(intent)
                        }
                        result.success(true)
                    }

                    "stopForegroundService" -> {
                        val intent = Intent(this@MainActivity, AssistantForegroundService::class.java).apply {
                            action = AssistantForegroundService.ACTION_STOP
                        }
                        startService(intent)
                        result.success(true)
                    }

                    "isBatteryOptimizationIgnored" -> {
                        val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
                        val isIgnored = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                            powerManager.isIgnoringBatteryOptimizations(packageName)
                        } else {
                            true
                        }
                        result.success(isIgnored)
                    }

                    "requestIgnoreBatteryOptimization" -> {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                            try {
                                val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
                                    data = Uri.parse("package:$packageName")
                                    flags = Intent.FLAG_ACTIVITY_NEW_TASK
                                }
                                startActivity(intent)
                                result.success(true)
                            } catch (e: Exception) {
                                val fallback = Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS).apply {
                                    flags = Intent.FLAG_ACTIVITY_NEW_TASK
                                }
                                startActivity(fallback)
                                result.success(true)
                            }
                        } else {
                            result.success(true)
                        }
                    }

                    "minimizeApp" -> {
                        moveTaskToBack(true)
                        result.success(true)
                    }

                    "isNotificationPermissionGranted" -> {
                        val granted = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                            checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) == android.content.pm.PackageManager.PERMISSION_GRANTED
                        } else {
                            true
                        }
                        result.success(granted)
                    }

                    "requestNotificationPermission" -> {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                            requestPermissions(arrayOf(android.Manifest.permission.POST_NOTIFICATIONS), 101)
                        }
                        result.success(true)
                    }

                    "isMicrophonePermissionGranted" -> {
                        val granted = checkSelfPermission(android.Manifest.permission.RECORD_AUDIO) == android.content.pm.PackageManager.PERMISSION_GRANTED
                        result.success(granted)
                    }

                    "requestMicrophonePermission" -> {
                        requestPermissions(arrayOf(android.Manifest.permission.RECORD_AUDIO), 102)
                        result.success(true)
                    }

                    "launchApp" -> {
                        val targetPkg = call.argument<String>("packageName") ?: ""
                        val launchIntent = packageManager.getLaunchIntentForPackage(targetPkg)
                        if (launchIntent != null) {
                            launchIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            startActivity(launchIntent)
                            result.success(true)
                        } else {
                            result.success(false)
                        }
                    }

                    "updateTrayStatus" -> {
                        val isActive = call.argument<Boolean>("isActive") ?: false
                        val statusText = call.argument<String>("statusText")
                        val intent = Intent(this@MainActivity, AssistantForegroundService::class.java).apply {
                            action = AssistantForegroundService.ACTION_UPDATE_STATUS
                            putExtra(AssistantForegroundService.EXTRA_IS_ACTIVE, isActive)
                            putExtra(AssistantForegroundService.EXTRA_STATUS_TEXT, statusText)
                        }
                        startService(intent)
                        result.success(true)
                    }

                    "writeAudioChunk" -> {
                        val bytes = call.argument<ByteArray>("bytes")
                        if (bytes != null) {
                            AssistantForegroundService.instance?.writeAudioChunk(bytes)
                            result.success(true)
                        } else {
                            result.success(false)
                        }
                    }

                    "flushAudio" -> {
                        AssistantForegroundService.instance?.flushAudio()
                        result.success(true)
                    }

                    "takeScreenCapture" -> {
                        AssistantAccessibilityService.instance?.takeScreenCapture { bytes ->
                            runOnUiThread {
                                result.success(bytes)
                            }
                        } ?: result.success(null)
                    }

                    "inputText" -> {
                        val text = call.argument<String>("text") ?: ""
                        val viewId = call.argument<String>("viewId")
                        val success = AssistantAccessibilityService.instance?.inputText(text, viewId) ?: false
                        result.success(success)
                    }

                    "scroll" -> {
                        val forward = call.argument<Boolean>("forward") ?: true
                        val success = AssistantAccessibilityService.instance?.scroll(forward) ?: false
                        result.success(success)
                    }

                    "startHotwordListening" -> {
                        val hotwords = call.argument<List<String>>("hotwords") ?: emptyList()
                        if (checkSelfPermission(android.Manifest.permission.RECORD_AUDIO) != android.content.pm.PackageManager.PERMISSION_GRANTED) {
                            requestPermissions(arrayOf(android.Manifest.permission.RECORD_AUDIO), 102)
                            result.success(false)
                        } else {
                            if (hotwords.isNotEmpty()) {
                                hotwordDetector?.updateHotwords(hotwords)
                            }
                            hotwordDetector?.startListening()
                            result.success(true)
                        }
                    }

                    "stopHotwordListening" -> {
                        hotwordDetector?.stopListening()
                        result.success(true)
                    }

                    "isHotwordListening" -> {
                        val isListening = hotwordDetector?.isListening() ?: false
                        result.success(isListening)
                    }

                    "speakText" -> {
                        val text = call.argument<String>("text") ?: ""
                        if (text.isNotEmpty()) {
                            textToSpeech?.speak(text, TextToSpeech.QUEUE_FLUSH, null, "device_assistant_tts")
                            result.success(true)
                        } else {
                            result.success(false)
                        }
                    }

                    "stopSpeaking" -> {
                        textToSpeech?.stop()
                        result.success(true)
                    }

                    else -> {
                        result.notImplemented()
                    }
                }
            }
        }

        // Forward active package changes and sensitive shield alerts to Flutter
        AssistantAccessibilityService.instance?.onWindowStateChangedListener = { pkg, isProtected ->
            runOnUiThread {
                methodChannel?.invokeMethod(
                    "onActivePackageChanged",
                    mapOf("packageName" to pkg, "isProtected" to isProtected)
                )
            }
        }

        // Forward top bar tray actions (Toggle Voice, Exit) to Flutter
        AssistantForegroundService.onTrayActionListener = { action ->
            runOnUiThread {
                methodChannel?.invokeMethod(
                    "onTrayAction",
                    mapOf("action" to action)
                )
            }
        }
    }

    private fun isAccessibilityServiceEnabled(context: Context): Boolean {
        val expectedComponentName = "${context.packageName}/${AssistantAccessibilityService::class.java.canonicalName}"
        val enabledServices = Settings.Secure.getString(
            context.contentResolver,
            Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES
        ) ?: return false

        return enabledServices.split(":").any { it.equals(expectedComponentName, ignoreCase = true) }
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == 102 && grantResults.isNotEmpty() && grantResults[0] == android.content.pm.PackageManager.PERMISSION_GRANTED) {
            hotwordDetector?.startListening()
            runOnUiThread {
                methodChannel?.invokeMethod("onMicrophonePermissionGranted", null)
            }
        }
    }

    override fun onDestroy() {
        hotwordDetector?.stopListening()
        textToSpeech?.stop()
        textToSpeech?.shutdown()
        super.onDestroy()
    }
}
