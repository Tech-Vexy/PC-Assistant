import 'dart:math' as math;
import 'dart:ui';
import 'package:flutter/material.dart';
import 'glass_container.dart';

/// Interactive multi-layer glassmorphic orb with expanding sound ripples,
/// specular reflections, and animated voice visualizers.
class AnimatedGlassOrb extends StatefulWidget {
  final bool isConnected;
  final bool isListening;
  final bool isSpeaking;
  final bool isConnecting;
  final VoidCallback onTap;

  const AnimatedGlassOrb({
    super.key,
    required this.isConnected,
    required this.isListening,
    required this.isSpeaking,
    required this.isConnecting,
    required this.onTap,
  });

  @override
  State<AnimatedGlassOrb> createState() => _AnimatedGlassOrbState();
}

class _AnimatedGlassOrbState extends State<AnimatedGlassOrb>
    with TickerProviderStateMixin {
  late final AnimationController _pulseController;
  late final AnimationController _rotationController;
  late final AnimationController _rippleController;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2200),
    )..repeat(reverse: true);

    _rotationController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 12),
    )..repeat();

    _rippleController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2400),
    );

    if (_isVoiceActive) _rippleController.repeat();
  }

  bool get _isVoiceActive =>
      widget.isConnected || widget.isListening || widget.isSpeaking;

  @override
  void didUpdateWidget(covariant AnimatedGlassOrb oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_isVoiceActive && !_rippleController.isAnimating) {
      _rippleController.repeat();
    } else if (!_isVoiceActive && _rippleController.isAnimating) {
      _rippleController.stop();
      _rippleController.reset();
    }
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _rotationController.dispose();
    _rippleController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final active = _isVoiceActive;

    // Dynamic color theme based on assistant mode
    final orbColors = widget.isSpeaking
        ? [
            const Color(0xFFFFB703),
            const Color(0xFFFB8500),
            const Color(0xFFD90429)
          ]
        : widget.isConnected
            ? [
                const Color(0xFF00F5D4),
                const Color(0xFF00B4D8),
                const Color(0xFF4361EE)
              ]
            : widget.isListening
                ? [
                    const Color(0xFF06D6A0),
                    const Color(0xFF118AB2),
                    const Color(0xFF073B4C)
                  ]
                : [
                    const Color(0xFF6C757D),
                    const Color(0xFF495057),
                    const Color(0xFF212529)
                  ];

    final glowColor = widget.isSpeaking
        ? const Color(0xFFFFB703)
        : widget.isConnected
            ? const Color(0xFF00F5D4)
            : widget.isListening
                ? const Color(0xFF06D6A0)
                : Colors.white24;

    const orbSize = 150.0;

    return Center(
      child: SizedBox(
        width: 250,
        height: 250,
        child: Stack(
          alignment: Alignment.center,
          children: [
            // Outward expanding ripple waves when active
            if (active) ...[
              _buildRippleRing(0.0, glowColor),
              _buildRippleRing(0.33, glowColor),
              _buildRippleRing(0.66, glowColor),
            ],

            // Ambient background glow halo
            AnimatedBuilder(
              animation: _pulseController,
              builder: (context, _) {
                final pulse = 0.85 + (_pulseController.value * 0.3);
                return Container(
                  width: orbSize * pulse,
                  height: orbSize * pulse,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color:
                            glowColor.withValues(alpha: active ? 0.45 : 0.12),
                        blurRadius: active ? 48 : 20,
                        spreadRadius: active ? 12 : 2,
                      ),
                    ],
                  ),
                );
              },
            ),

            // Glassmorphic Orb Body
            GestureDetector(
              onTap: widget.onTap,
              child: AnimatedBuilder(
                animation: _pulseController,
                builder: (context, _) {
                  final scale =
                      active ? 1.0 + (_pulseController.value * 0.06) : 1.0;
                  return Transform.scale(
                    scale: scale,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(orbSize / 2),
                      child: BackdropFilter(
                        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
                        child: Container(
                          width: orbSize,
                          height: orbSize,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: RadialGradient(
                              center: const Alignment(-0.35, -0.45),
                              radius: 0.95,
                              colors: [
                                Colors.white.withValues(
                                    alpha: 0.45), // Specular light highlight
                                ...orbColors
                                    .map((c) => c.withValues(alpha: 0.7)),
                                const Color(0xFF0A0C12).withValues(alpha: 0.85),
                              ],
                              stops: const [0.0, 0.25, 0.65, 1.0],
                            ),
                            border: Border.all(
                              color: Colors.white.withValues(alpha: 0.35),
                              width: 1.8,
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.4),
                                blurRadius: 20,
                                offset: const Offset(0, 10),
                              ),
                            ],
                          ),
                          child: Stack(
                            alignment: Alignment.center,
                            children: [
                              // Internal orbiting shimmer highlight
                              AnimatedBuilder(
                                animation: _rotationController,
                                builder: (context, _) {
                                  return Transform.rotate(
                                    angle:
                                        _rotationController.value * 2 * math.pi,
                                    child: Align(
                                      alignment: Alignment.topRight,
                                      child: Container(
                                        width: 44,
                                        height: 44,
                                        margin: const EdgeInsets.all(16),
                                        decoration: BoxDecoration(
                                          shape: BoxShape.circle,
                                          gradient: RadialGradient(
                                            colors: [
                                              Colors.white
                                                  .withValues(alpha: 0.5),
                                              Colors.white
                                                  .withValues(alpha: 0.0),
                                            ],
                                          ),
                                        ),
                                      ),
                                    ),
                                  );
                                },
                              ),

                              // Central status icon or spinner
                              if (widget.isConnecting)
                                const SizedBox(
                                  width: 44,
                                  height: 44,
                                  child: CircularProgressIndicator(
                                    color: Colors.white,
                                    strokeWidth: 3.2,
                                  ),
                                )
                              else
                                Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      active
                                          ? Icons.graphic_eq
                                          : Icons.mic_none,
                                      size: 42,
                                      color: Colors.white,
                                      shadows: [
                                        Shadow(
                                          color: glowColor,
                                          blurRadius: 12,
                                        ),
                                      ],
                                    ),
                                    if (active) ...[
                                      const SizedBox(height: 6),
                                      AnimatedVoiceVisualizer(
                                        isActive: active,
                                        color: glowColor,
                                        height: 14,
                                      ),
                                    ],
                                  ],
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRippleRing(double delay, Color color) {
    return AnimatedBuilder(
      animation: _rippleController,
      builder: (context, _) {
        final progress = (_rippleController.value + delay) % 1.0;
        final size = 150.0 + (progress * 90.0);
        final opacity = (1.0 - progress).clamp(0.0, 1.0) * 0.45;

        return Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(
              color: color.withValues(alpha: opacity),
              width: 1.5,
            ),
          ),
        );
      },
    );
  }
}
