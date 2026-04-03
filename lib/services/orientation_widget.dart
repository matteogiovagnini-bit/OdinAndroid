// lib/features/sensors/orientation_widget.dart
//
// Widget Flutter che mostra Pitch e Roll in tempo reale
// con la stessa livella a bolla della pagina HTML dell'ESP32.
// Da includere nella HomePage o in qualsiasi schermata.
//
// Uso:
//   OrientationWidget(service: myOrientationService)

import 'dart:async';
import 'package:flutter/material.dart';
import 'orientation_service.dart';

class OrientationWidget extends StatefulWidget {
  final OrientationService service;
  const OrientationWidget({super.key, required this.service});

  @override
  State<OrientationWidget> createState() => _OrientationWidgetState();
}

class _OrientationWidgetState extends State<OrientationWidget> {
  late StreamSubscription<OrientationData> _sub;
  double _pitch = 0.0;
  double _roll  = 0.0;

  @override
  void initState() {
    super.initState();
    _sub = widget.service.stream.listen((data) {
      if (mounted) setState(() { _pitch = data.pitch; _roll = data.roll; });
    });
  }

  @override
  void dispose() {
    _sub.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      color: const Color(0xFF111827),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Orientamento',
              style: TextStyle(color: Colors.white70, fontSize: 14),
            ),
            const SizedBox(height: 16),
            _BubbleLevel(pitch: _pitch, roll: _roll),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _ValChip(label: 'Pitch', value: _pitch),
                const SizedBox(width: 16),
                _ValChip(label: 'Roll', value: _roll),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ── Livella a bolla ──────────────────────────────────────────
class _BubbleLevel extends StatelessWidget {
  final double pitch;
  final double roll;
  static const double _maxDeg  = 45.0;
  static const double _size    = 180.0;
  static const double _bubble  = 28.0;
  static const double _radius  = (_size / 2) - (_bubble / 2) - 4;

  const _BubbleLevel({required this.pitch, required this.roll});

  @override
  Widget build(BuildContext context) {
    final clampedPitch = pitch.clamp(-_maxDeg, _maxDeg);
    final clampedRoll  = roll.clamp(-_maxDeg, _maxDeg);
    final dx = (clampedRoll  / _maxDeg) * _radius;
    final dy = (clampedPitch / _maxDeg) * _radius;

    return SizedBox(
      width: _size,
      height: _size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Sfondo circolare
          Container(
            width: _size,
            height: _size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: const Color(0xFF0b1220),
              border: Border.all(color: const Color(0xFF243041), width: 1.5),
            ),
          ),
          // Reticolo
          CustomPaint(size: const Size(_size, _size), painter: _GridPainter()),
          // Cerchio target
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: Colors.white24,
                width: 1,
                strokeAlign: BorderSide.strokeAlignInside,
              ),
            ),
          ),
          // Bolla
          AnimatedPositioned(
            duration: const Duration(milliseconds: 120),
            curve: Curves.easeOut,
            left:  (_size / 2) + dx - (_bubble / 2),
            top:   (_size / 2) + dy - (_bubble / 2),
            child: Container(
              width: _bubble,
              height: _bubble,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: const RadialGradient(
                  center: Alignment(-0.3, -0.3),
                  colors: [Color(0xFF93c5fd), Color(0xFF2563eb), Color(0xFF1d4ed8)],
                  stops: [0.0, 0.5, 1.0],
                ),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFF2563eb).withOpacity(0.5),
                    blurRadius: 10,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// Reticolo SVG-like via CustomPainter
class _GridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xFF243041)
      ..strokeWidth = 0.8;
    final center = Offset(size.width / 2, size.height / 2);
    final r = size.width / 2;
    // Clip al cerchio
    canvas.save();
    canvas.clipPath(Path()..addOval(Rect.fromCircle(center: center, radius: r)));
    // Linee orizzontali e verticali
    for (final offset in [-r / 2, 0.0, r / 2]) {
      canvas.drawLine(Offset(0, center.dy + offset), Offset(size.width, center.dy + offset), paint);
      canvas.drawLine(Offset(center.dx + offset, 0), Offset(center.dx + offset, size.height), paint);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_GridPainter old) => false;
}

// Chip Pitch/Roll
class _ValChip extends StatelessWidget {
  final String label;
  final double value;
  const _ValChip({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF0b1220),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF243041)),
      ),
      child: Column(
        children: [
          Text(label, style: const TextStyle(color: Colors.white54, fontSize: 11)),
          const SizedBox(height: 2),
          Text(
            '${value.toStringAsFixed(1)}°',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.w600,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}
