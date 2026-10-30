package com.deviceassistant.device_assistant

import android.accessibilityservice.AccessibilityButtonController
import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.AccessibilityServiceInfo
import android.accessibilityservice.GestureDescription
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Path
import android.graphics.Rect
import android.os.Build
import android.os.Bundle
import android.view.Display
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import java.io.ByteArrayOutputStream
import java.util.concurrent.Executors

class AssistantAccessibilityService : AccessibilityService() {

    companion object {
        var instance: AssistantAccessibilityService? = null
            private set

        // Built-in blacklist of sensitive packages (SIM Toolkit, Banking, 2FA)
        private val protectedPackages = setOf(
            "com.android.stk",
            "com.android.stk2",
            "com.mediatek.stk",
            "com.qualcomm.qti.uim",
            "com.samsung.android.app.telephonyui.stk",
            "ke.co.safaricom.mpesa",
            "com.safaricom.mpesa.lifestyle",
            "com.airtel.africa.airtelmoney",
            "com.mtn.mymtn",
            "com.chase.sig.android",
            "com.infonow.bofa",
            "com.wf.wellsfargomobile",
            "com.revolut.revolut",
            "co.monzo",
            "com.paypal.android.p2pmobile",
            "com.squareup.cash",
            "io.metamask",
            "com.coinbase.android",
            "com.wallet.crypto.trustapp",
            "com.onepassword.android",
            "com.x8bit.bitwarden",
            "com.google.android.apps.authenticator2",
            "com.authy.authy"
        )
    }

    var activePackageName: String? = null
        private set

    var onWindowStateChangedListener: ((packageName: String, isProtected: Boolean) -> Unit)? = null

    private val customProtectedPackages = mutableSetOf<String>()
    private val screenshotExecutor = Executors.newSingleThreadExecutor()
    private var buttonCallback: AccessibilityButtonController.AccessibilityButtonCallback? = null

    fun updateCustomProtectedPackages(packages: List<String>) {
        synchronized(customProtectedPackages) {
            customProtectedPackages.clear()
            customProtectedPackages.addAll(packages.map { it.lowercase() })
        }
    }

    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = this

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            try {
                val info = serviceInfo ?: AccessibilityServiceInfo()
                info.flags = info.flags or AccessibilityServiceInfo.FLAG_REQUEST_ACCESSIBILITY_BUTTON
                serviceInfo = info

                val controller = accessibilityButtonController
                val cb = object : AccessibilityButtonController.AccessibilityButtonCallback() {
                    override fun onClicked(controller: AccessibilityButtonController) {
                        handleAccessibilityShortcutClicked()
                    }
                }
                buttonCallback = cb
                controller.registerAccessibilityButtonCallback(cb)
            } catch (_: Exception) {}
        }
    }

    private fun handleAccessibilityShortcutClicked() {
        // Deliver ACTION_TOGGLE_VOICE to the foreground service.
        // The service calls toggleListening() directly — no activity is started,
        // so the app is never brought to the foreground.
        val svc = AssistantForegroundService.instance
        if (svc != null) {
            // Service is alive — call toggleListening() directly (no IPC needed).
            svc.toggleListening()
        } else {
            // Service not running yet — start it with the toggle action.
            val intent = Intent(this, AssistantForegroundService::class.java).apply {
                action = AssistantForegroundService.ACTION_TOGGLE_VOICE
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                startForegroundService(intent)
            } else {
                startService(intent)
            }
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && buttonCallback != null) {
            try {
                accessibilityButtonController.unregisterAccessibilityButtonCallback(buttonCallback!!)
            } catch (_: Exception) {}
            buttonCallback = null
        }
        try {
            screenshotExecutor.shutdown()
        } catch (_: Exception) {}
        if (instance == this) {
            instance = null
        }
    }

    override fun onInterrupt() {
        // Handle accessibility interruption
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        if (event == null) return

        if (event.eventType == AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED) {
            val pkg = event.packageName?.toString() ?: return
            activePackageName = pkg

            val isProtected = isPackageProtected(pkg)
            onWindowStateChangedListener?.invoke(pkg, isProtected)
        }
    }

    fun isPackageProtected(packageName: String): Boolean {
        val lower = packageName.lowercase()
        if (lower.contains(".stk") || lower.endsWith(".stk") || lower.contains("simtoolkit")) {
            return true
        }
        val isCustom = synchronized(customProtectedPackages) {
            customProtectedPackages.contains(lower)
        }
        return isCustom || protectedPackages.contains(lower)
    }

    private fun isCurrentPackageProtected(): Boolean {
        val pkg = activePackageName
        return pkg != null && isPackageProtected(pkg)
    }

    /**
     * Finds and clicks a UI element by visible text or resource ID
     */
    fun clickByText(text: String, viewId: String? = null): Boolean {
        if (isCurrentPackageProtected()) {
            return false // Guarded against protected apps
        }
        val root = rootInActiveWindow ?: return false
        val nodes = if (!viewId.isNullOrBlank()) {
            root.findAccessibilityNodeInfosByViewId(viewId)
        } else {
            root.findAccessibilityNodeInfosByText(text)
        }
        for (node in nodes) {
            if (node.isClickable && node.performAction(AccessibilityNodeInfo.ACTION_CLICK)) {
                return true
            }
            // If the node itself is not clickable, try its parent
            var parent = node.parent
            while (parent != null) {
                if (parent.isClickable && parent.performAction(AccessibilityNodeInfo.ACTION_CLICK)) {
                    return true
                }
                parent = parent.parent
            }
        }
        return false
    }

    /**
     * Injects a tap gesture at normalized or absolute coordinates
     */
    fun injectTap(x: Float, y: Float, callback: ((Boolean) -> Unit)? = null): Boolean {
        if (isCurrentPackageProtected()) {
            callback?.invoke(false)
            return false
        }

        val path = Path().apply {
            moveTo(x, y)
        }
        val stroke = GestureDescription.StrokeDescription(path, 0, 50)
        val gesture = GestureDescription.Builder().addStroke(stroke).build()

        return dispatchGesture(gesture, object : GestureResultCallback() {
            override fun onCompleted(gestureDescription: GestureDescription?) {
                callback?.invoke(true)
            }
            override fun onCancelled(gestureDescription: GestureDescription?) {
                callback?.invoke(false)
            }
        }, null)
    }

    /**
     * Injects a swipe gesture from (startX, startY) to (endX, endY)
     */
    fun injectSwipe(startX: Float, startY: Float, endX: Float, endY: Float, durationMs: Long = 300): Boolean {
        if (isCurrentPackageProtected()) {
            return false
        }

        val path = Path().apply {
            moveTo(startX, startY)
            lineTo(endX, endY)
        }
        val stroke = GestureDescription.StrokeDescription(path, 0, durationMs)
        val gesture = GestureDescription.Builder().addStroke(stroke).build()

        return dispatchGesture(gesture, null, null)
    }

    /**
     * Performs a system-level navigation action (Home, Back, Recents, Notifications)
     */
    fun performNavigation(action: Int): Boolean {
        return performGlobalAction(action)
    }

    /**
     * Recursively dumps the non-sensitive semantic view hierarchy for LLM understanding
     */
    fun dumpWindowHierarchy(): List<Map<String, Any>> {
        if (isCurrentPackageProtected()) {
            return emptyList()
        }

        val root = rootInActiveWindow ?: return emptyList()
        val elements = mutableListOf<Map<String, Any>>()
        traverseNode(root, elements)
        return elements
    }

    private fun traverseNode(node: AccessibilityNodeInfo?, list: MutableList<Map<String, Any>>) {
        if (node == null) return

        val bounds = Rect()
        node.getBoundsInScreen(bounds)
        val viewId = node.viewIdResourceName

        // Sensitive password masking to prevent exfiltration
        if (node.isPassword) {
            val item = mutableMapOf<String, Any>(
                "className" to (node.className?.toString() ?: ""),
                "clickable" to node.isClickable,
                "isPassword" to true,
                "text" to "••••••••",
                "bounds" to mapOf(
                    "left" to bounds.left,
                    "top" to bounds.top,
                    "right" to bounds.right,
                    "bottom" to bounds.bottom
                )
            )
            if (viewId != null) item["id"] = viewId
            list.add(item)
            return
        }

        val text = node.text?.toString()
        val contentDesc = node.contentDescription?.toString()

        if (!text.isNullOrBlank() || !contentDesc.isNullOrBlank() || node.isClickable) {
            val item = mutableMapOf<String, Any>(
                "className" to (node.className?.toString() ?: ""),
                "clickable" to node.isClickable,
                "bounds" to mapOf(
                    "left" to bounds.left,
                    "top" to bounds.top,
                    "right" to bounds.right,
                    "bottom" to bounds.bottom
                )
            )
            if (!text.isNullOrBlank()) item["text"] = text
            if (!contentDesc.isNullOrBlank()) item["contentDescription"] = contentDesc
            if (viewId != null) item["id"] = viewId

            list.add(item)
        }

        for (i in 0 until node.childCount) {
            traverseNode(node.getChild(i), list)
        }
    }

    /**
     * Captures a JPEG screenshot via AccessibilityService.takeScreenshot (API 30+)
     * Returns null if active package is protected by SensitiveAppGuard.
     */
    fun takeScreenCapture(callback: (ByteArray?) -> Unit) {
        if (isCurrentPackageProtected()) {
            callback(null)
            return
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            takeScreenshot(Display.DEFAULT_DISPLAY, screenshotExecutor, object : TakeScreenshotCallback {
                override fun onSuccess(screenshot: ScreenshotResult) {
                    try {
                        val hardwareBuffer = screenshot.hardwareBuffer
                        val colorSpace = screenshot.colorSpace
                        val bitmap = Bitmap.wrapHardwareBuffer(hardwareBuffer, colorSpace)
                            ?.copy(Bitmap.Config.ARGB_8888, false)
                        hardwareBuffer.close()

                        if (bitmap != null) {
                            val stream = ByteArrayOutputStream()
                            bitmap.compress(Bitmap.CompressFormat.JPEG, 80, stream)
                            val bytes = stream.toByteArray()
                            bitmap.recycle()
                            callback(bytes)
                        } else {
                            callback(null)
                        }
                    } catch (e: Exception) {
                        callback(null)
                    }
                }

                override fun onFailure(errorCode: Int) {
                    callback(null)
                }
            })
        } else {
            callback(null)
        }
    }

    /**
     * Injects text into an editable input field (or currently focused field)
     */
    fun inputText(text: String, viewId: String? = null): Boolean {
        if (isCurrentPackageProtected()) {
            return false
        }
        val root = rootInActiveWindow ?: return false

        val targetNode: AccessibilityNodeInfo? = if (!viewId.isNullOrBlank()) {
            val nodes = root.findAccessibilityNodeInfosByViewId(viewId)
            nodes.firstOrNull { it.isEditable } ?: nodes.firstOrNull()
        } else {
            root.findFocus(AccessibilityNodeInfo.FOCUS_INPUT)
        }

        if (targetNode != null) {
            val arguments = Bundle().apply {
                putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, text)
            }
            return targetNode.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, arguments)
        }
        return false
    }

    /**
     * Performs a scroll forward (down) or backward (up) on the scrollable container
     */
    fun scroll(forward: Boolean = true): Boolean {
        if (isCurrentPackageProtected()) {
            return false
        }
        val root = rootInActiveWindow ?: return false
        val action = if (forward) AccessibilityNodeInfo.ACTION_SCROLL_FORWARD else AccessibilityNodeInfo.ACTION_SCROLL_BACKWARD

        fun findAndScroll(node: AccessibilityNodeInfo?): Boolean {
            if (node == null) return false
            if (node.isScrollable && node.performAction(action)) {
                return true
            }
            for (i in 0 until node.childCount) {
                if (findAndScroll(node.getChild(i))) return true
            }
            return false
        }

        return findAndScroll(root)
    }
}
