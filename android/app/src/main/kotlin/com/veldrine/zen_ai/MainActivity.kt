package com.veldrine.zen_ai

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.provider.Settings
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.Locale
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.veldrine.zen_ai/bridge"
    private var methodChannel: MethodChannel? = null
    private var hotwordDetector: HotwordDetector? = null
    private var textToSpeech: TextToSpeech? = null
    private var isTtsInitialized: Boolean = false
    private val pendingTtsQueue: MutableList<String> = mutableListOf()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        hotwordDetector = HotwordDetector(
            context = this,
            onHotwordTriggered = { hotword, command ->
                runOnUiThread {
                    methodChannel?.invokeMethod(
                        "onHotwordDetected",
                        mapOf("hotword" to hotword, "command" to command)
                    )
                }
            },
            onRmsChangedListener = { rms ->
                runOnUiThread {
                    methodChannel?.invokeMethod(
                        "onAudioRmsChanged",
                        mapOf("rms" to rms.toDouble())
                    )
                }
            },
            onPartialTranscriptListener = { partial ->
                runOnUiThread {
                    methodChannel?.invokeMethod(
                        "onPartialTranscript",
                        mapOf("text" to partial)
                    )
                }
            }
        )

        initTextToSpeech()

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
                        val dispatched = AssistantAccessibilityService.instance?.injectTap(x, y) { gestureSuccess ->
                            runOnUiThread { result.success(gestureSuccess) }
                        } ?: false
                        if (!dispatched) {
                            // dispatchGesture returned false — accessibility service unavailable or protected app
                            result.success(false)
                        }
                        // If dispatched == true, result is sent asynchronously from the gesture callback above
                    }

                    "injectSwipe" -> {
                        val startX = (call.argument<Double>("startX") ?: 0.0).toFloat()
                        val startY = (call.argument<Double>("startY") ?: 0.0).toFloat()
                        val endX = (call.argument<Double>("endX") ?: 0.0).toFloat()
                        val endY = (call.argument<Double>("endY") ?: 0.0).toFloat()
                        val duration = (call.argument<Int>("durationMs") ?: 300).toLong()

                        val service = AssistantAccessibilityService.instance
                        if (service == null) {
                            result.success(false)
                        } else {
                            val path = android.graphics.Path().apply {
                                moveTo(startX, startY)
                                lineTo(endX, endY)
                            }
                            val stroke = android.accessibilityservice.GestureDescription.StrokeDescription(path, 0, duration)
                            val gesture = android.accessibilityservice.GestureDescription.Builder().addStroke(stroke).build()
                            val dispatched = service.dispatchGesture(gesture, object : android.accessibilityservice.AccessibilityService.GestureResultCallback() {
                                override fun onCompleted(gestureDescription: android.accessibilityservice.GestureDescription?) {
                                    runOnUiThread { result.success(true) }
                                }
                                override fun onCancelled(gestureDescription: android.accessibilityservice.GestureDescription?) {
                                    runOnUiThread { result.success(false) }
                                }
                            }, null)
                            if (!dispatched) {
                                result.success(false)
                            }
                        }
                    }

                    "performNavigation" -> {
                        val action = call.argument<Int>("action") ?: 1
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
                        val target = call.argument<String>("packageName") ?: call.argument<String>("appName") ?: ""
                        val success = resolveAndLaunchApp(target)
                        result.success(success)
                    }

                    "launchSystemIntent" -> {
                        val action = call.argument<String>("action") ?: ""
                        val uriStr = call.argument<String>("uri")
                        val extras = call.argument<Map<String, Any>>("extras") ?: emptyMap()
                        val success = launchSystemIntent(action, uriStr, extras)
                        result.success(success)
                    }

                    "getInstalledApps" -> {
                        val apps = getInstalledAppsList()
                        result.success(apps)
                    }

                    "getContacts" -> {
                        val filter = call.argument<String>("query")
                        val contacts = queryDeviceContacts(filter)
                        result.success(contacts)
                    }

                    "isDeviceAdminActive" -> {
                        val dpm = getSystemService(Context.DEVICE_POLICY_SERVICE) as android.app.admin.DevicePolicyManager
                        val adminComponent = android.content.ComponentName(this@MainActivity, AssistantDeviceAdminReceiver::class.java)
                        result.success(dpm.isAdminActive(adminComponent))
                    }

                    "requestDeviceAdmin" -> {
                        val adminComponent = android.content.ComponentName(this@MainActivity, AssistantDeviceAdminReceiver::class.java)
                        val intent = Intent(android.app.admin.DevicePolicyManager.ACTION_ADD_DEVICE_ADMIN).apply {
                            putExtra(android.app.admin.DevicePolicyManager.EXTRA_DEVICE_ADMIN, adminComponent)
                            putExtra(
                                android.app.admin.DevicePolicyManager.EXTRA_ADD_EXPLANATION,
                                "Device Assistant requires administrative elevation to enforce security policies and lock the device."
                            )
                            flags = Intent.FLAG_ACTIVITY_NEW_TASK
                        }
                        startActivity(intent)
                        result.success(true)
                    }

                    "lockDeviceNow" -> {
                        val dpm = getSystemService(Context.DEVICE_POLICY_SERVICE) as android.app.admin.DevicePolicyManager
                        val adminComponent = android.content.ComponentName(this@MainActivity, AssistantDeviceAdminReceiver::class.java)
                        if (dpm.isAdminActive(adminComponent)) {
                            dpm.lockNow()
                            result.success(true)
                        } else {
                            result.success(false)
                        }
                    }

                    "openDefaultAssistantSettings" -> {
                        val intent = Intent(Settings.ACTION_VOICE_INPUT_SETTINGS).apply {
                            flags = Intent.FLAG_ACTIVITY_NEW_TASK
                        }
                        try {
                            startActivity(intent)
                            result.success(true)
                        } catch (_: Exception) {
                            val fallback = Intent(Settings.ACTION_MANAGE_DEFAULT_APPS_SETTINGS).apply {
                                flags = Intent.FLAG_ACTIVITY_NEW_TASK
                            }
                            startActivity(fallback)
                            result.success(true)
                        }
                    }

                    "isNotificationListenerEnabled" -> {
                        result.success(AssistantNotificationListenerService.isEnabled(this@MainActivity))
                    }

                    "openNotificationListenerSettings" -> {
                        AssistantNotificationListenerService.openSettings(this@MainActivity)
                        result.success(true)
                    }

                    "getActiveNotifications" -> {
                        val list = AssistantNotificationListenerService.getNotificationsList()
                        result.success(list)
                    }

                    "replyToNotification" -> {
                        val key = call.argument<String>("key") ?: ""
                        val replyText = call.argument<String>("replyText") ?: ""
                        if (key.isBlank() || replyText.isBlank()) {
                            result.success(false)
                        } else {
                            val replied = AssistantNotificationListenerService.reply(this@MainActivity, key, replyText)
                            result.success(replied)
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
                            // Prefer the service-owned detector so there is only one
                            // SpeechRecognizer active and it survives when the activity is
                            // backgrounded (e.g. after tapping the accessibility button).
                            val detector = AssistantForegroundService.instance?.getHotwordDetector()
                                ?: hotwordDetector
                            if (detector != null) {
                                if (hotwords.isNotEmpty()) {
                                    detector.updateHotwords(hotwords)
                                }
                                detector.startListening()
                                result.success(true)
                            } else {
                                result.success(false)
                            }
                        }
                    }

                    "stopHotwordListening" -> {
                        val detector = AssistantForegroundService.instance?.getHotwordDetector()
                            ?: hotwordDetector
                        detector?.stopListening()
                        result.success(true)
                    }

                    "isHotwordListening" -> {
                        val detector = AssistantForegroundService.instance?.getHotwordDetector()
                            ?: hotwordDetector
                        val isListening = detector?.isListening() ?: false
                        result.success(isListening)
                    }

                    "speakText" -> {
                        val text = call.argument<String>("text") ?: ""
                        if (text.isNotEmpty()) {
                            val ok = speak(text)
                            result.success(ok)
                        } else {
                            result.success(false)
                        }
                    }

                    "stopSpeaking" -> {
                        pendingTtsQueue.clear()
                        textToSpeech?.stop()
                        hotwordDetector?.resumeListening()
                        result.success(true)
                    }

                    "isUsageAccessGranted" -> {
                        result.success(isUsageAccessGranted())
                    }

                    "requestUsageAccess" -> {
                        val intent = Intent(Settings.ACTION_USAGE_ACCESS_SETTINGS).apply {
                            flags = Intent.FLAG_ACTIVITY_NEW_TASK
                        }
                        try {
                            startActivity(intent)
                        } catch (e: Exception) {
                            // Fallback to generic app settings if exact page unavailable
                            startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                                data = Uri.parse("package:$packageName")
                                flags = Intent.FLAG_ACTIVITY_NEW_TASK
                            })
                        }
                        result.success(true)
                    }

                    "sendSms" -> {
                        val phoneNumber = call.argument<String>("phoneNumber") ?: ""
                        val message = call.argument<String>("message") ?: ""
                        if (phoneNumber.isBlank() || message.isBlank()) {
                            result.success(mapOf("status" to "error", "error" to "phoneNumber and message are required"))
                        } else {
                            try {
                                val smsManager = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                                    context.getSystemService(android.telephony.SmsManager::class.java)
                                } else {
                                    @Suppress("DEPRECATION")
                                    android.telephony.SmsManager.getDefault()
                                }
                                val parts = smsManager.divideMessage(message)
                                if (parts.size > 1) {
                                    smsManager.sendMultipartTextMessage(phoneNumber, null, parts, null, null)
                                } else {
                                    smsManager.sendTextMessage(phoneNumber, null, message, null, null)
                                }
                                result.success(mapOf(
                                    "status" to "sent",
                                    "phone_number" to phoneNumber,
                                    "message" to message
                                ))
                            } catch (e: Exception) {
                                result.success(mapOf(
                                    "status" to "error",
                                    "error" to (e.message ?: "Failed to send SMS")
                                ))
                            }
                        }
                    }

                    "getSmsMessages" -> {
                        val limit = call.argument<Int>("limit") ?: 50
                        try {
                            val messages = mutableListOf<Map<String, Any?>>()
                            val cursor = contentResolver.query(
                                android.provider.Telephony.Sms.Inbox.CONTENT_URI,
                                arrayOf("_id", "address", "body", "date", "type"),
                                null, null, "date DESC"
                            )
                            cursor?.use { c ->
                                val idIdx = c.getColumnIndex("_id")
                                val addrIdx = c.getColumnIndex("address")
                                val bodyIdx = c.getColumnIndex("body")
                                val dateIdx = c.getColumnIndex("date")
                                val typeIdx = c.getColumnIndex("type")
                                var count = 0
                                while (c.moveToNext() && count < limit) {
                                    messages.add(mapOf(
                                        "id" to (if (idIdx >= 0) c.getInt(idIdx) else 0),
                                        "address" to (if (addrIdx >= 0) c.getString(addrIdx) else ""),
                                        "body" to (if (bodyIdx >= 0) c.getString(bodyIdx) else ""),
                                        "date" to (if (dateIdx >= 0) c.getLong(dateIdx) else 0L),
                                        "type" to (if (typeIdx >= 0) c.getInt(typeIdx) else 1)
                                    ))
                                    count++
                                }
                            }
                            result.success(mapOf(
                                "status" to "done",
                                "count" to messages.size,
                                "messages" to messages
                            ))
                        } catch (e: Exception) {
                            result.success(mapOf(
                                "status" to "error",
                                "error" to (e.message ?: "Failed to query SMS")
                            ))
                        }
                    }

                    "makeCall" -> {
                        val phoneNumber = call.argument<String>("phoneNumber") ?: ""
                        if (phoneNumber.isBlank()) {
                            result.success(mapOf("status" to "error", "error" to "phoneNumber is required"))
                        } else {
                            try {
                                val hasCallPerm = checkSelfPermission(android.Manifest.permission.CALL_PHONE) == android.content.pm.PackageManager.PERMISSION_GRANTED
                                val intent = Intent(if (hasCallPerm) Intent.ACTION_CALL else Intent.ACTION_DIAL, Uri.parse("tel:$phoneNumber")).apply {
                                    flags = Intent.FLAG_ACTIVITY_NEW_TASK
                                }
                                startActivity(intent)
                                result.success(mapOf(
                                    "status" to "calling",
                                    "phone_number" to phoneNumber
                                ))
                            } catch (e: Exception) {
                                result.success(mapOf(
                                    "status" to "error",
                                    "error" to (e.message ?: "Failed to make call")
                                ))
                            }
                        }
                    }

                    "operateDialerCall" -> {
                        val contactName = call.argument<String>("contactName") ?: ""
                        val phoneNumber = call.argument<String>("phoneNumber") ?: ""
                        val simSlot = call.argument<Int>("simSlot") ?: 1
                        val simName = call.argument<String>("simName")

                        operateDialerCall(contactName, phoneNumber, simSlot, simName) { res ->
                            runOnUiThread { result.success(res) }
                        }
                    }

                    "isTelephonyAvailable" -> {
                        val tm = getSystemService(Context.TELEPHONY_SERVICE) as? android.telephony.TelephonyManager
                        val available = tm != null && tm.phoneType != android.telephony.TelephonyManager.PHONE_TYPE_NONE
                        result.success(available)
                    }

                    "getNetworkInfo" -> {
                        try {
                            val tm = getSystemService(Context.TELEPHONY_SERVICE) as? android.telephony.TelephonyManager
                            val networkOperator = tm?.networkOperatorName ?: "unknown"
                            result.success(mapOf(
                                "status" to "done",
                                "network_type" to "mobile",
                                "carrier" to networkOperator,
                                "platform" to "android"
                            ))
                        } catch (e: Exception) {
                            result.success(mapOf(
                                "status" to "error",
                                "error" to (e.message ?: "Unknown error")
                            ))
                        }
                    }

                    else -> {
                        result.notImplemented()
                    }
                }
            }
        }

        // Register this channel in the foreground service so it can deliver hotword
        // and transcript callbacks to Flutter even when the activity is backgrounded.
        AssistantForegroundService.methodChannel = methodChannel

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

    private fun initTextToSpeech() {
        textToSpeech = TextToSpeech(this) { status ->
            if (status == TextToSpeech.SUCCESS) {
                var langResult = textToSpeech?.setLanguage(Locale.getDefault())
                if (langResult == TextToSpeech.LANG_MISSING_DATA || langResult == TextToSpeech.LANG_NOT_SUPPORTED) {
                    textToSpeech?.setLanguage(Locale.US)
                }

                textToSpeech?.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
                    override fun onStart(utteranceId: String?) {
                        hotwordDetector?.pauseListening()
                        runOnUiThread {
                            methodChannel?.invokeMethod("onTtsStarted", null)
                        }
                    }

                    override fun onDone(utteranceId: String?) {
                        hotwordDetector?.resumeListening()
                        runOnUiThread {
                            methodChannel?.invokeMethod("onTtsCompleted", null)
                        }
                    }

                    @Deprecated("Deprecated in Java")
                    override fun onError(utteranceId: String?) {
                        hotwordDetector?.resumeListening()
                        runOnUiThread {
                            methodChannel?.invokeMethod("onTtsCompleted", null)
                        }
                    }

                    override fun onError(utteranceId: String?, errorCode: Int) {
                        hotwordDetector?.resumeListening()
                        runOnUiThread {
                            methodChannel?.invokeMethod("onTtsCompleted", null)
                        }
                    }
                })

                isTtsInitialized = true
                for (pending in pendingTtsQueue) {
                    speak(pending)
                }
                pendingTtsQueue.clear()
            }
        }
    }

    private fun speak(text: String): Boolean {
        if (!isTtsInitialized || textToSpeech == null) {
            pendingTtsQueue.add(text)
            return true
        }
        val params = Bundle().apply {
            putString(TextToSpeech.Engine.KEY_PARAM_UTTERANCE_ID, "device_assistant_${System.currentTimeMillis()}")
        }
        val res = textToSpeech?.speak(text, TextToSpeech.QUEUE_FLUSH, params, "device_assistant_tts")
        return res == TextToSpeech.SUCCESS
    }

    /**
     * Resolves and launches an application by package name or human-readable app label.
     *
     * Scoring (highest wins, ties broken by shorter label = more specific):
     *   100 – exact package name match
     *    90 – exact label match (case-insensitive)
     *    80 – label contains the full query as a contiguous substring
     *    70 – all query words appear as word-boundary tokens in the label
     *    50 – all normalized query tokens are present in normalized label
     *    20 – label contains any single query word
     */
    private fun resolveAndLaunchApp(query: String): Boolean {
        if (query.isBlank()) return false
        val cleanQuery = query.trim()
        val lowerQuery = cleanQuery.lowercase()

        // ── 1. Direct exact package name ────────────────────────────────────
        val directIntent = packageManager.getLaunchIntentForPackage(cleanQuery)
        if (directIntent != null) {
            directIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivity(directIntent)
            return true
        }

        // ── 2. Enumerate all launcher activities ────────────────────────────
        val launcherIntent = Intent(Intent.ACTION_MAIN, null).apply {
            addCategory(Intent.CATEGORY_LAUNCHER)
        }
        val resolveList = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            packageManager.queryIntentActivities(
                launcherIntent,
                android.content.pm.PackageManager.ResolveInfoFlags.of(0L)
            )
        } else {
            @Suppress("DEPRECATION")
            packageManager.queryIntentActivities(launcherIntent, 0)
        }

        // ── 3. Score every candidate ─────────────────────────────────────────
        data class ScoredApp(val pkg: String, val label: String, val score: Int)

        val queryWords = lowerQuery.split(Regex("\\s+")).filter { it.isNotBlank() }
        val normalizedQuery = lowerQuery.replace(Regex("[^a-z0-9\\s]"), "").trim()
        val normalizedQueryTokens = normalizedQuery.split(Regex("\\s+")).filter { it.isNotBlank() }

        val scored = mutableListOf<ScoredApp>()

        for (info in resolveList) {
            val pkg = info.activityInfo.packageName
            val label = info.loadLabel(packageManager).toString().trim()
            val lowerLabel = label.lowercase()
            val lowerPkg = pkg.lowercase()
            val normalizedLabel = lowerLabel.replace(Regex("[^a-z0-9\\s]"), "").trim()

            var score = 0

            when {
                // Exact package name (case-insensitive)
                lowerPkg == lowerQuery -> score = 100

                // Exact label
                lowerLabel == lowerQuery -> score = 90

                // Full query substring in label (e.g. "chrome dev" in "google chrome dev")
                lowerLabel.contains(lowerQuery) -> score = 80

                // Full normalized query in normalized label
                normalizedLabel.contains(normalizedQuery) -> score = 75

                // All query words appear as word-boundary tokens in label
                queryWords.isNotEmpty() && queryWords.all { w ->
                    lowerLabel.split(Regex("[\\s\\-_.:]+")).any { token -> token == w }
                } -> score = 70

                // All query words appear somewhere in label
                queryWords.isNotEmpty() && queryWords.all { w -> lowerLabel.contains(w) } -> score = 60

                // All normalized tokens present in normalized label
                normalizedQueryTokens.isNotEmpty() && normalizedQueryTokens.all { t ->
                    normalizedLabel.contains(t)
                } -> score = 50

                // Package contains all query words
                queryWords.isNotEmpty() && queryWords.all { w -> lowerPkg.contains(w) } -> score = 45

                // Any single query word in label (last-resort)
                queryWords.any { w -> w.length >= 4 && lowerLabel.contains(w) } -> score = 20

                // Any single query word in package
                queryWords.any { w -> w.length >= 4 && lowerPkg.contains(w) } -> score = 10
            }

            if (score > 0) {
                scored.add(ScoredApp(pkg, label, score))
            }
        }

        if (scored.isEmpty()) {
            // ── 4. Common alias fallback ──────────────────────────────────────
            return tryCommonAliases(lowerQuery)
        }

        // Sort: highest score first, then shortest label (more specific name wins)
        val best = scored.sortedWith(compareByDescending<ScoredApp> { it.score }.thenBy { it.label.length })
            .firstOrNull() ?: return tryCommonAliases(lowerQuery)

        val intent = packageManager.getLaunchIntentForPackage(best.pkg) ?: return false
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        startActivity(intent)
        return true
    }

    /** Attempts to launch an app via well-known package aliases for common app names. */
    private fun tryCommonAliases(lowerQuery: String): Boolean {
        val commonAliases = mapOf(
            "camera" to listOf("com.google.android.GoogleCamera", "com.android.camera", "com.sec.android.app.camera"),
            "photos" to listOf("com.google.android.apps.photos", "com.android.gallery3d", "com.sec.android.gallery3d"),
            "gallery" to listOf("com.google.android.apps.photos", "com.android.gallery3d", "com.sec.android.gallery3d"),
            "browser" to listOf("com.android.chrome", "org.mozilla.firefox", "com.sec.android.app.sbrowser"),
            "chrome" to listOf("com.android.chrome"),
            "settings" to listOf("com.android.settings"),
            "clock" to listOf("com.google.android.deskclock", "com.android.deskclock", "com.sec.android.app.clockpackage"),
            "calculator" to listOf("com.google.android.calculator", "com.android.calculator2", "com.sec.android.app.popupcalculator"),
            "calendar" to listOf("com.google.android.calendar", "com.android.calendar", "com.samsung.android.calendar"),
            "contacts" to listOf("com.google.android.contacts", "com.android.contacts", "com.samsung.android.app.contacts"),
            "maps" to listOf("com.google.android.apps.maps"),
            "youtube" to listOf("com.google.android.youtube"),
            "gmail" to listOf("com.google.android.gm"),
            "messages" to listOf("com.google.android.apps.messaging", "com.android.mms", "com.samsung.android.messaging"),
            "phone" to listOf("com.google.android.dialer", "com.android.dialer", "com.samsung.android.dialer"),
            "dialer" to listOf("com.google.android.dialer", "com.android.dialer", "com.samsung.android.dialer")
        )
        for ((alias, packages) in commonAliases) {
            if (lowerQuery.contains(alias)) {
                for (pkg in packages) {
                    val intent = packageManager.getLaunchIntentForPackage(pkg)
                    if (intent != null) {
                        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        startActivity(intent)
                        return true
                    }
                }
            }
        }
        return false
    }

    private fun launchSystemIntent(action: String, uriStr: String?, extras: Map<String, Any>): Boolean {
        return try {
            val intent = when (action.lowercase()) {
                "dial", "call" -> {
                    val uri = if (!uriStr.isNullOrBlank()) Uri.parse(uriStr) else null
                    if (uri != null) Intent(Intent.ACTION_DIAL, uri) else Intent(Intent.ACTION_DIAL)
                }
                "sms", "send_sms" -> {
                    val uri = if (!uriStr.isNullOrBlank()) Uri.parse(uriStr) else Uri.parse("smsto:")
                    Intent(Intent.ACTION_SENDTO, uri).apply {
                        extras["sms_body"]?.let { putExtra("sms_body", it.toString()) }
                    }
                }
                "settings" -> {
                    val settingType = extras["type"]?.toString()?.lowercase()
                    when (settingType) {
                        "wifi" -> Intent(Settings.ACTION_WIFI_SETTINGS)
                        "bluetooth" -> Intent(Settings.ACTION_BLUETOOTH_SETTINGS)
                        "sound", "volume" -> Intent(Settings.ACTION_SOUND_SETTINGS)
                        "display" -> Intent(Settings.ACTION_DISPLAY_SETTINGS)
                        "date", "time" -> Intent(Settings.ACTION_DATE_SETTINGS)
                        "battery" -> Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)
                        "apps", "applications" -> Intent(Settings.ACTION_MANAGE_APPLICATIONS_SETTINGS)
                        "accessibility" -> Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)
                        "assistant", "voice" -> Intent(Settings.ACTION_VOICE_INPUT_SETTINGS)
                        else -> Intent(Settings.ACTION_SETTINGS)
                    }
                }
                "alarm", "set_alarm" -> {
                    Intent(android.provider.AlarmClock.ACTION_SET_ALARM).apply {
                        extras["hour"]?.let { putExtra(android.provider.AlarmClock.EXTRA_HOUR, (it as? Number)?.toInt() ?: 0) }
                        extras["minutes"]?.let { putExtra(android.provider.AlarmClock.EXTRA_MINUTES, (it as? Number)?.toInt() ?: 0) }
                        extras["message"]?.let { putExtra(android.provider.AlarmClock.EXTRA_MESSAGE, it.toString()) }
                        putExtra(android.provider.AlarmClock.EXTRA_SKIP_UI, false)
                    }
                }
                "show_alarms" -> Intent(android.provider.AlarmClock.ACTION_SHOW_ALARMS)
                "camera" -> Intent(android.provider.MediaStore.ACTION_IMAGE_CAPTURE)
                "view", "browse" -> {
                    val uri = if (!uriStr.isNullOrBlank()) Uri.parse(uriStr) else null
                    if (uri != null) Intent(Intent.ACTION_VIEW, uri) else return false
                }
                "search", "web_search" -> {
                    Intent(Intent.ACTION_WEB_SEARCH).apply {
                        extras["query"]?.let { putExtra(android.app.SearchManager.QUERY, it.toString()) }
                    }
                }
                "contacts" -> Intent(Intent.ACTION_VIEW, android.provider.ContactsContract.Contacts.CONTENT_URI)
                else -> {
                    val uri = if (!uriStr.isNullOrBlank()) Uri.parse(uriStr) else null
                    if (uri != null) Intent(action, uri) else Intent(action)
                }
            }

            intent.flags = Intent.FLAG_ACTIVITY_NEW_TASK
            startActivity(intent)
            true
        } catch (_: Exception) {
            false
        }
    }

    private fun getInstalledAppsList(): List<Map<String, String>> {
        val launcherIntent = Intent(Intent.ACTION_MAIN, null).apply {
            addCategory(Intent.CATEGORY_LAUNCHER)
        }
        val resolveList = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            packageManager.queryIntentActivities(
                launcherIntent,
                android.content.pm.PackageManager.ResolveInfoFlags.of(0L)
            )
        } else {
            @Suppress("DEPRECATION")
            packageManager.queryIntentActivities(launcherIntent, 0)
        }

        val result = mutableListOf<Map<String, String>>()
        for (info in resolveList) {
            val pkg = info.activityInfo.packageName
            val label = info.loadLabel(packageManager).toString().trim()
            result.add(mapOf("appName" to label, "packageName" to pkg))
        }
        return result
    }

    private fun queryDeviceContacts(filter: String?): List<Map<String, String>> {
        val contacts = mutableListOf<Map<String, String>>()
        if (checkSelfPermission(android.Manifest.permission.READ_CONTACTS) != android.content.pm.PackageManager.PERMISSION_GRANTED) {
            requestPermissions(arrayOf(android.Manifest.permission.READ_CONTACTS), 103)
            return contacts
        }

        try {
            val uri = android.provider.ContactsContract.CommonDataKinds.Phone.CONTENT_URI
            val projection = arrayOf(
                android.provider.ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME,
                android.provider.ContactsContract.CommonDataKinds.Phone.NUMBER
            )
            val selection = if (!filter.isNullOrBlank()) {
                "${android.provider.ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME} LIKE ?"
            } else null
            val selectionArgs = if (!filter.isNullOrBlank()) arrayOf("%$filter%") else null

            contentResolver.query(uri, projection, selection, selectionArgs, null)?.use { cursor ->
                val nameIdx = cursor.getColumnIndex(android.provider.ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME)
                val numberIdx = cursor.getColumnIndex(android.provider.ContactsContract.CommonDataKinds.Phone.NUMBER)
                while (cursor.moveToNext()) {
                    val name = if (nameIdx != -1) cursor.getString(nameIdx) ?: "" else ""
                    val number = if (numberIdx != -1) cursor.getString(numberIdx) ?: "" else ""
                    if (name.isNotEmpty() || number.isNotEmpty()) {
                        contacts.add(mapOf("name" to name, "phoneNumber" to number))
                    }
                }
            }
        } catch (_: Exception) {}
        return contacts
    }

    private fun isAccessibilityServiceEnabled(context: Context): Boolean {
        val expectedComponentName = "${context.packageName}/${AssistantAccessibilityService::class.java.canonicalName}"
        val enabledServices = Settings.Secure.getString(
            context.contentResolver,
            Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES
        ) ?: return false

        return enabledServices.split(":").any { it.equals(expectedComponentName, ignoreCase = true) }
    }

    /**
     * Returns true if the user has granted Package Usage Stats (Usage Access) permission.
     * Required for PACKAGE_USAGE_STATS which is an AppOps permission, not a runtime permission.
     */
    private fun isUsageAccessGranted(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
            try {
                val appOps = getSystemService(Context.APP_OPS_SERVICE) as android.app.AppOpsManager
                val mode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    appOps.unsafeCheckOpNoThrow(
                        android.app.AppOpsManager.OPSTR_GET_USAGE_STATS,
                        android.os.Process.myUid(),
                        packageName
                    )
                } else {
                    @Suppress("DEPRECATION")
                    appOps.checkOpNoThrow(
                        android.app.AppOpsManager.OPSTR_GET_USAGE_STATS,
                        android.os.Process.myUid(),
                        packageName
                    )
                }
                mode == android.app.AppOpsManager.MODE_ALLOWED
            } catch (e: Exception) {
                false
            }
        } else {
            true
        }
    }

    private fun operateDialerCall(
        contactName: String,
        phoneNumberArg: String,
        simSlot: Int,
        simName: String?,
        callback: (Map<String, Any?>) -> Unit
    ) {
        var resolvedNumber = phoneNumberArg.trim()
        var resolvedName = contactName.trim()

        // 1. Resolve contact number from device contacts if not provided
        if (resolvedNumber.isEmpty() && resolvedName.isNotEmpty()) {
            try {
                val cursor = contentResolver.query(
                    android.provider.ContactsContract.CommonDataKinds.Phone.CONTENT_URI,
                    arrayOf(
                        android.provider.ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME,
                        android.provider.ContactsContract.CommonDataKinds.Phone.NUMBER
                    ),
                    "${android.provider.ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME} LIKE ?",
                    arrayOf("%$resolvedName%"),
                    null
                )
                cursor?.use { c ->
                    if (c.moveToFirst()) {
                        val nameIdx = c.getColumnIndex(android.provider.ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME)
                        val numIdx = c.getColumnIndex(android.provider.ContactsContract.CommonDataKinds.Phone.NUMBER)
                        if (nameIdx >= 0) resolvedName = c.getString(nameIdx)
                        if (numIdx >= 0) resolvedNumber = c.getString(numIdx)
                    }
                }
            } catch (_: Exception) {}
        }

        // 2. Launch Default Phone / Dialer App
        try {
            val dialIntent = if (resolvedNumber.isNotEmpty()) {
                Intent(Intent.ACTION_DIAL, Uri.parse("tel:${Uri.encode(resolvedNumber)}")).apply {
                    flags = Intent.FLAG_ACTIVITY_NEW_TASK
                }
            } else {
                val telecomManager = getSystemService(Context.TELECOM_SERVICE) as? android.telecom.TelecomManager
                val defaultDialer = telecomManager?.defaultDialerPackage
                if (defaultDialer != null) {
                    packageManager.getLaunchIntentForPackage(defaultDialer)?.apply {
                        flags = Intent.FLAG_ACTIVITY_NEW_TASK
                    } ?: Intent(Intent.ACTION_DIAL).apply { flags = Intent.FLAG_ACTIVITY_NEW_TASK }
                } else {
                    Intent(Intent.ACTION_DIAL).apply { flags = Intent.FLAG_ACTIVITY_NEW_TASK }
                }
            }

            startActivity(dialIntent)
        } catch (e: Exception) {
            callback(mapOf(
                "status" to "error",
                "error" to "Failed to launch default dialer: ${e.message}"
            ))
            return
        }

        // 3. UI Automation via Accessibility Service
        val scheduler = Executors.newSingleThreadScheduledExecutor()
        scheduler.schedule({
            try {
                val service = AssistantAccessibilityService.instance
                if (service == null) {
                    callback(mapOf(
                        "status" to "dialer_opened",
                        "contact_name" to resolvedName,
                        "phone_number" to resolvedNumber,
                        "warning" to "Dialer opened, but Accessibility Service is disabled. Please enable it in Settings for automated dialing and SIM selection."
                    ))
                    return@schedule
                }

                // If number was unknown and only contact name is present, search in dialer
                if (resolvedNumber.isEmpty() && resolvedName.isNotEmpty()) {
                    service.inputText(resolvedName)
                    Thread.sleep(700)
                    service.findAndClickContact(resolvedName)
                    Thread.sleep(500)
                }

                // Click Call button in dialer UI
                val callClicked = service.clickCallButton()

                // Wait briefly for dual SIM chooser dialog / bottom sheet
                Thread.sleep(700)
                val simChosen = service.chooseSimCard(simSlot, simName)

                callback(mapOf(
                    "status" to "calling",
                    "contact_name" to resolvedName,
                    "phone_number" to resolvedNumber,
                    "sim_slot" to simSlot,
                    "sim_name" to simName,
                    "call_button_clicked" to callClicked,
                    "sim_chosen" to simChosen,
                    "method" to "dialer_ui_automation"
                ))
            } catch (e: Exception) {
                callback(mapOf(
                    "status" to "error",
                    "error" to (e.message ?: "Automation error")
                ))
            } finally {
                scheduler.shutdown()
            }
        }, 1200, TimeUnit.MILLISECONDS)
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
        // Clear static reference to avoid leaking a dead channel
        if (AssistantForegroundService.methodChannel == methodChannel) {
            AssistantForegroundService.methodChannel = null
        }
        super.onDestroy()
    }
}
