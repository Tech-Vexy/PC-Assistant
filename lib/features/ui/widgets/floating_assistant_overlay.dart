import 'package:flutter/material.dart';
import 'glass_container.dart';

/// Floating glassmorphic overlay pill providing ambient visual feedback when the assistant
/// is actively listening or executing commands in the background without foregrounding.
class FloatingAssistantOverlay extends StatelessWidget {
  final bool isListening;
  final bool isSpeaking;
  final String transcript;
  final VoidCallback onDismiss;

  const FloatingAssistantOverlay({
    super.key,
    required this.isListening,
    required this.isSpeaking,
    required this.transcript,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    if (!isListening && !isSpeaking && transcript.isEmpty) {
      return const SizedBox.shrink();
    }

    final accentColor = isListening
        ? Colors.tealAccent
        : isSpeaking
            ? Colors.amberAccent
            : Colors.cyanAccent;

    return Positioned(
      top: 48,
      left: 16,
      right: 16,
      child: Material(
        color: Colors.transparent,
        child: GlassContainer(
          blur: 20,
          opacity: 0.12,
          borderRadius: BorderRadius.circular(28),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          border: Border.all(
            color: accentColor.withValues(alpha: 0.4),
            width: 1.3,
          ),
          shadows: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.35),
              blurRadius: 16,
              offset: const Offset(0, 6),
            ),
            BoxShadow(
              color: accentColor.withValues(alpha: 0.2),
              blurRadius: 12,
              spreadRadius: 1,
            ),
          ],
          child: Row(
            children: [
              // Voice activity soundwave visualizer
              AnimatedVoiceVisualizer(
                isActive: isListening || isSpeaking,
                color: accentColor,
                height: 18,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  transcript.isNotEmpty
                      ? transcript
                      : isListening
                          ? 'Listening...'
                          : isSpeaking
                              ? 'Speaking...'
                              : 'Ready',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    letterSpacing: 0.2,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                icon: const Icon(Icons.close, size: 16, color: Colors.white70),
                onPressed: onDismiss,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
