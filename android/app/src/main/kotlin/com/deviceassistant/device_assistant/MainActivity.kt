package com.deviceassistant.device_assistant

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

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.deviceassistant/bridge"
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

                    "getInstalledApps" -> {
                        val apps = getInstalledAppsList()
                        result.success(apps)
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
