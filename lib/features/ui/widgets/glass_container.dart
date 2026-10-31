import 'dart:math' as math;
import 'dart:ui';
import 'package:flutter/material.dart';

/// Highly customizable glassmorphic container with frosted backdrop blur,
/// specular edge highlights, and subtle depth gradient.
class GlassContainer extends StatelessWidget {
  final Widget child;
  final double blur;
  final double opacity;
  final BorderRadius? borderRadius;
  final Border? border;
  final Color? color;
  final LinearGradient? gradient;
  final List<BoxShadow>? shadows;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;
  final double? width;
  final double? height;
  final Clip clipBehavior;

  const GlassContainer({
    super.key,
    required this.child,
    this.blur = 16.0,
    this.opacity = 0.08,
    this.borderRadius,
    this.border,
    this.color,
    this.gradient,
    this.shadows,
    this.padding,
    this.margin,
    this.width,
    this.height,
    this.clipBehavior = Clip.antiAlias,
  });

  @override
  Widget build(BuildContext context) {
    final effectiveBorderRadius = borderRadius ?? BorderRadius.circular(16);
    final effectiveBorder = border ??
        Border.all(
          color: Colors.white.withValues(alpha: 0.16),
          width: 1.2,
        );

    final effectiveGradient = gradient ??
        LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            (color ?? Colors.white).withValues(alpha: opacity * 1.8),
            (color ?? Colors.white).withValues(alpha: opacity * 0.6),
          ],
        );

    Widget content = Container(
      width: width,
      height: height,
      padding: padding,
      decoration: BoxDecoration(
        borderRadius: effectiveBorderRadius,
        border: effectiveBorder,
        gradient: effectiveGradient,
        boxShadow: shadows ??
            [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.25),
                blurRadius: 18,
                spreadRadius: 0,
                offset: const Offset(0, 8),
              ),
            ],
      ),
      child: child,
    );

    if (blur > 0) {
      content = ClipRRect(
        borderRadius: effectiveBorderRadius,
        clipBehavior: clipBehavior,
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
          child: content,
        ),
      );
    }

    if (margin != null) {
      content = Padding(padding: margin!, child: content);
    }

    return content;
  }
}

/// Ambient liquid aurora background with smoothly morphing glowing blobs.
/// Provides rich luminous color highlights that refract through frosted glass surfaces.
class AnimatedAuroraBackground extends StatefulWidget {
  final Widget child;

  const AnimatedAuroraBackground({super.key, required this.child});

  @override
  State<AnimatedAuroraBackground> createState() =>
      _AnimatedAuroraBackgroundState();
}

class _AnimatedAuroraBackgroundState extends State<AnimatedAuroraBackground>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 14),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        // Deep obsidian base
        Container(color: const Color(0xFF0C0E14)),

        // Flowing animated aurora mesh
        AnimatedBuilder(
          animation: _controller,
          builder: (context, _) {
            final t = _controller.value * 2 * math.pi;
            return CustomPaint(
              painter: _AuroraPainter(time: t),
              size: Size.infinite,
            );
          },
        ),

        // Subtle dark vignette overlay to preserve high-contrast readability
        Container(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              center: Alignment.center,
              radius: 1.4,
              colors: [
                Colors.transparent,
                const Color(0xFF0C0E14).withValues(alpha: 0.65),
              ],
            ),
          ),
        ),

        // Foreground application content
        widget.child,
      ],
    );
  }
}

class _AuroraPainter extends CustomPainter {
  final double time;

  _AuroraPainter({required this.time});

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;

    // Orb 1: Glowing Cyan / Aqua
    final x1 = w * 0.25 + math.sin(time) * (w * 0.15);
    final y1 = h * 0.28 + math.cos(time * 0.8) * (h * 0.12);
    final r1 = math.min(w, h) * 0.55;
    final paint1 = Paint()
      ..shader = RadialGradient(
        colors: [
          const Color(0xFF00F5D4).withValues(alpha: 0.22),
          const Color(0xFF00B4D8).withValues(alpha: 0.08),
          Colors.transparent,
        ],
        stops: const [0.0, 0.5, 1.0],
      ).createShader(Rect.fromCircle(center: Offset(x1, y1), radius: r1));
    canvas.drawCircle(Offset(x1, y1), r1, paint1);

    // Orb 2: Deep Indigo / Violet
    final x2 = w * 0.75 + math.cos(time * 0.7) * (w * 0.18);
    final y2 = h * 0.45 + math.sin(time * 0.9) * (h * 0.14);
    final r2 = math.min(w, h) * 0.65;
    final paint2 = Paint()
      ..shader = RadialGradient(
        colors: [
          const Color(0xFF7928CA).withValues(alpha: 0.25),
          const Color(0xFF4361EE).withValues(alpha: 0.10),
          Colors.transparent,
        ],
        stops: const [0.0, 0.55, 1.0],
      ).createShader(Rect.fromCircle(center: Offset(x2, y2), radius: r2));
    canvas.drawCircle(Offset(x2, y2), r2, paint2);

    // Orb 3: Radiant Magenta / Coral
    final x3 = w * 0.40 + math.sin(time * 1.1) * (w * 0.2);
    final y3 = h * 0.80 + math.cos(time * 0.6) * (h * 0.15);
    final r3 = math.min(w, h) * 0.50;
    final paint3 = Paint()
      ..shader = RadialGradient(
        colors: [
          const Color(0xFFFF007F).withValues(alpha: 0.16),
          const Color(0xFF7209B7).withValues(alpha: 0.06),
          Colors.transparent,
        ],
        stops: const [0.0, 0.6, 1.0],
      ).createShader(Rect.fromCircle(center: Offset(x3, y3), radius: r3));
    canvas.drawCircle(Offset(x3, y3), r3, paint3);
  }

  @override
  bool shouldRepaint(covariant _AuroraPainter oldDelegate) =>
      oldDelegate.time != time;
}

/// Dynamic 5-bar soundwave frequency visualizer that pulses during audio activity.
class AnimatedVoiceVisualizer extends StatefulWidget {
  final bool isActive;
  final Color color;
  final double height;

  const AnimatedVoiceVisualizer({
    super.key,
    required this.isActive,
    this.color = Colors.tealAccent,
    this.height = 20,
  });

  @override
  State<AnimatedVoiceVisualizer> createState() =>
      _AnimatedVoiceVisualizerState();
}

class _AnimatedVoiceVisualizerState extends State<AnimatedVoiceVisualizer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    if (widget.isActive) _controller.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(covariant AnimatedVoiceVisualizer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isActive && !_controller.isAnimating) {
      _controller.repeat(reverse: true);
    } else if (!widget.isActive && _controller.isAnimating) {
      _controller.stop();
      _controller.reset();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const bars = 5;
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: List.generate(bars, (i) {
            final phase = (i * 0.22);
            final val = widget.isActive
                ? (math.sin((_controller.value * 2 * math.pi) + phase).abs() *
                        0.7 +
                    0.3)
                : 0.25;
            final barH = widget.height * val;
            return Container(
              margin: const EdgeInsets.symmetric(horizontal: 1.5),
              width: 3,
              height: barH,
              decoration: BoxDecoration(
                color: widget.color.withValues(alpha: widget.isActive ? 0.9 : 0.4),
                borderRadius: BorderRadius.circular(4),
                boxShadow: widget.isActive
                    ? [
                        BoxShadow(
                          color: widget.color.withValues(alpha: 0.4),
                          blurRadius: 4,
                          spreadRadius: 0.5,
                        )
                      ]
                    : null,
              ),
            );
          }),
        );
      },
    );
  }
}

/// Glassmorphic action button with smooth hover/press animations.
class GlassActionButton extends StatefulWidget {
  final IconData icon;
  final VoidCallback onPressed;
  final String? tooltip;
  final bool primary;
  final bool active;
  final double size;

  const GlassActionButton({
    super.key,
    required this.icon,
    required this.onPressed,
    this.tooltip,
    this.primary = false,
    this.active = false,
    this.size = 46,
  });

  @override
  State<GlassActionButton> createState() => _GlassActionButtonState();
}

class _GlassActionButtonState extends State<GlassActionButton> {
  bool _isPressed = false;

  @override
  Widget build(BuildContext context) {
    final activeColor = widget.primary
        ? Colors.indigoAccent
        : widget.active
            ? Colors.tealAccent
            : Colors.white;

    final bgColor = widget.primary
        ? Colors.indigo.withValues(alpha: 0.35)
        : widget.active
            ? Colors.teal.withValues(alpha: 0.25)
            : Colors.white.withValues(alpha: 0.08);

    final borderColor = widget.primary
        ? Colors.indigoAccent.withValues(alpha: 0.6)
        : widget.active
            ? Colors.tealAccent.withValues(alpha: 0.6)
            : Colors.white.withValues(alpha: 0.18);

    Widget btn = GestureDetector(
      onTapDown: (_) => setState(() => _isPressed = true),
      onTapUp: (_) => setState(() => _isPressed = false),
      onTapCancel: () => setState(() => _isPressed = false),
      onTap: widget.onPressed,
      child: AnimatedScale(
        scale: _isPressed ? 0.92 : 1.0,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOutCubic,
        child: GlassContainer(
          width: widget.size,
          height: widget.size,
          blur: 14,
          opacity: 0.1,
          borderRadius: BorderRadius.circular(widget.size / 2),
          border: Border.all(color: borderColor, width: 1.2),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              bgColor,
              bgColor.withValues(alpha: 0.4),
            ],
          ),
          shadows: widget.active || widget.primary
              ? [
                  BoxShadow(
                    color: activeColor.withValues(alpha: 0.35),
                    blurRadius: 12,
                    spreadRadius: 1,
                  ),
                ]
              : null,
          child: Center(
            child: Icon(
              widget.icon,
              size: widget.size * 0.46,
              color: activeColor,
            ),
          ),
        ),
      ),
    );

    if (widget.tooltip != null) {
      btn = Tooltip(message: widget.tooltip!, child: btn);
    }

    return btn;
  }
}
