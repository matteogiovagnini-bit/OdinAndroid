import 'dart:math' as math;
import 'package:flutter/material.dart';

class AnimatedEyesWidget extends StatefulWidget {
  final double pitch;
  final double roll;
  final double yaw;
  final bool isListening;
  final bool isSpeaking;
  final String emotion; // 'neutral', 'happy', 'surprised', 'thinking'

  const AnimatedEyesWidget({
    super.key,
    this.pitch = 0.0,
    this.roll = 0.0,
    this.yaw = 0.0,
    this.isListening = false,
    this.isSpeaking = false,
    this.emotion = 'neutral',
  });

  @override
  State<AnimatedEyesWidget> createState() => _AnimatedEyesWidgetState();
}

class _AnimatedEyesWidgetState extends State<AnimatedEyesWidget>
    with SingleTickerProviderStateMixin {
  late AnimationController _blinkController;
  late Animation<double> _blinkAnimation;
  DateTime _lastBlink = DateTime.now();

  @override
  void initState() {
    super.initState();
    _blinkController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 150),
    );

    _blinkAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _blinkController, curve: Curves.easeInOut),
    )..addStatusListener((status) {
        if (status == AnimationStatus.completed) {
          _blinkController.reverse();
        }
      });

    _scheduleBlink();
  }

  void _scheduleBlink() {
    Future.delayed(Duration(milliseconds: 2000 + math.Random().nextInt(3000)), () {
      if (mounted) {
        _blinkController.forward();
        _scheduleBlink();
      }
    });
  }

  @override
  void dispose() {
    _blinkController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 1.6,
      child: Container(
        decoration: BoxDecoration(
          color: Colors.black,
          borderRadius: BorderRadius.circular(20),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 30),
        child: AnimatedBuilder(
          animation: _blinkAnimation,
          builder: (context, child) {
            return Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _buildEye(isLeft: true),
                _buildEye(isLeft: false),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildEye({required bool isLeft}) {
    final blinkValue = _blinkAnimation.value;
    final eyeSize = const Size(120, 120);
    final pupilOffset = _calculatePupilOffset(isLeft);

    return SizedBox(
      width: eyeSize.width + 20,
      height: eyeSize.height + 20,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Occhio bianco (sclera)
          Container(
            width: eyeSize.width,
            height: eyeSize.height * (1.0 - blinkValue * 0.8),
            decoration: BoxDecoration(
              color: Colors.white,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.3),
                  blurRadius: 8,
                  offset: const Offset(2, 4),
                ),
              ],
              border: Border.all(
                color: Colors.grey.shade300,
                width: 2,
              ),
            ),
          ),

          // Pupilla
          if (blinkValue < 0.5)
            Transform.translate(
              offset: pupilOffset,
              child: Container(
                width: 50,
                height: 50,
                decoration: BoxDecoration(
                  color: Colors.black,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.5),
                      blurRadius: 4,
                      offset: const Offset(1, 2),
                    ),
                  ],
                ),
                child: Center(
                  child: Container(
                    width: 15,
                    height: 15,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.8),
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              ),
            ),

          // Ciglia superiore (per blink)
          if (blinkValue > 0)
            Container(
              width: eyeSize.width,
              height: eyeSize.height * blinkValue * 0.5,
              decoration: BoxDecoration(
                color: Colors.black,
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(60),
                  topRight: Radius.circular(60),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Offset _calculatePupilOffset(bool isLeft) {
    final maxOffset = 25.0;
    final yawFactor = isLeft ? -1.0 : 1.0;

    double dx = 0.0;
    double dy = 0.0;

    // Yaw influenzala direzione orizzontale
    dx = (widget.yaw * 0.3).clamp(-maxOffset, maxOffset) * yawFactor;

    // Pitch influenzala direzione verticale
    dy = (widget.pitch * 0.3).clamp(-maxOffset, maxOffset);

    // Roll per inclinazione
    final rollRad = widget.roll * math.pi / 180;
    final rotatedDx = dx * math.cos(rollRad) - dy * math.sin(rollRad);
    final rotatedDy = dx * math.sin(rollRad) + dy * math.cos(rollRad);

    return Offset(rotatedDx, rotatedDy);
  }
}
