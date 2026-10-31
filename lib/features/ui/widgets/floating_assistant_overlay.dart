import 'package:flutter/material.dart';

/// Floating overlay pill widget providing ambient visual feedback when the assistant
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

    return Positioned(
      top: 48,
      left: 16,
      right: 16,
      child: Material(
        color: Colors.transparent,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: const Color(0xE61E293B), // Translucent slate
            borderRadius: BorderRadius.circular(24),
            border: Border.all(
              color: isListening
                  ? Colors.tealAccent
                  : isSpeaking
                      ? Colors.amberAccent
                      : Colors.white24,
              width: 1.5,
            ),
            boxShadow: const [
              BoxShadow(
                color: Colors.black45,
                blurRadius: 12,
                offset: Offset(0, 4),
              ),
            ],
          ),
          child: Row(
            children: [
              // Pulsing/animated status dot
              Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: isListening
                      ? Colors.tealAccent
                      : isSpeaking
                          ? Colors.amberAccent
                          : Colors.grey,
                ),
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
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
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
