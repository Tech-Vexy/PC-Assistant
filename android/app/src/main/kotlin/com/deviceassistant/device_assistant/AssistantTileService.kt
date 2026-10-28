package com.deviceassistant.device_assistant

import android.content.Intent
import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import androidx.annotation.RequiresApi

/**
 * Android Quick Settings Top Bar Tile allowing quick access to
 * Device Assistant directly from the top pull-down system bar,
 * mirroring the system tray experience on Windows and Linux.
 */
@RequiresApi(Build.VERSION_CODES.N)
class AssistantTileService : TileService() {

    override fun onStartListening() {
        super.onStartListening()
        updateTileState()
    }

    override fun onClick() {
        super.onClick()

        // Toggle voice listening via foreground service
        val isListening = AssistantForegroundService.isVoiceActive

        val intent = Intent(this, AssistantForegroundService::class.java).apply {
            action = AssistantForegroundService.ACTION_TOGGLE_VOICE
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(intent)
        } else {
            startService(intent)
        }

        // Optimistically update tile state
        val tile = qsTile ?: return
        tile.state = if (isListening) Tile.STATE_INACTIVE else Tile.STATE_ACTIVE
        tile.subtitle = if (isListening) "Idle" else "Listening"
        tile.updateTile()
    }

    private fun updateTileState() {
        val tile = qsTile ?: return
        val isActive = AssistantForegroundService.isVoiceActive

        tile.state = if (isActive) Tile.STATE_ACTIVE else Tile.STATE_INACTIVE
        tile.label = "Device Assistant"
        tile.subtitle = if (isActive) "Listening" else "Tap to Speak"
        tile.updateTile()
    }
}
