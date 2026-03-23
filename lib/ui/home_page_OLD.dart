import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../services/assistant_service.dart';
import '../services/tts_service.dart';
import '../services/vosk_command_service.dart';
import '../services/wake_phrase_service.dart';
import '../services/voice_assistant_controller.dart';

const bool kUseVisualAvatarUi = true;
const bool kUseDiabolikStyle = true;

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with TickerProviderStateMixin {
  late final VoiceAssistantController _controller;

  StreamSubscription<String>? _statusSub;
  StreamSubscription<String>? _partialSub;
  StreamSubscription<String>? _finalSub;
  StreamSubscription<AssistantState>? _stateSub;

  String _status = 'Avvio assistente...';
  String _partialText = '';
  String _finalText = '';
  AssistantState _assistantState = AssistantState.stopped;

  late final AnimationController _speakController;
  late final AnimationController _listenController;
  late final AnimationController _blinkController;

  @override
  void initState() {
    super.initState();

    _speakController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    );

    _listenController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );

    _blinkController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
    );

    _controller = VoiceAssistantController(
      wakePhraseService: WakePhraseService(),
      commandService: VoskCommandService(),
      ttsService: TtsService(),
      assistantService: AssistantService(),
    );

    _statusSub = _controller.statusStream.listen((value) {
      if (!mounted) return;
      setState(() {
        _status = value;
      });
    });

    _partialSub = _controller.partialStream.listen((value) {
      if (!mounted) return;
      setState(() {
        _partialText = value;
      });
    });

    _finalSub = _controller.finalStream.listen((value) {
      if (!mounted) return;
      setState(() {
        _finalText = value;
      });
    });

    _stateSub = _controller.stateStream.listen((value) {
      if (!mounted) return;

      setState(() {
        _assistantState = value;
      });

      _updateAnimationsForState(value);
    });

    _startAssistant();
  }

  void _updateAnimationsForState(AssistantState state) {
    switch (state) {
      case AssistantState.idleWakeWord:
        _speakController.stop();
        _listenController.repeat(reverse: true);
        _scheduleBlink();
        break;
      case AssistantState.listeningCommand:
        _speakController.stop();
        _listenController.repeat(reverse: true);
        break;
      case AssistantState.processing:
        _speakController.stop();
        _listenController.repeat(reverse: true);
        break;
      case AssistantState.speaking:
        _listenController.stop();
        _speakController.repeat(reverse: true);
        break;
      case AssistantState.stopped:
        _speakController.stop();
        _listenController.stop();
        break;
    }
  }

  Future<void> _scheduleBlink() async {
    if (!mounted) return;
    if (_assistantState != AssistantState.idleWakeWord) return;

    await Future.delayed(const Duration(seconds: 4));
    if (!mounted) return;
    if (_assistantState != AssistantState.idleWakeWord) return;

    await _blinkController.forward(from: 0);
    await _blinkController.reverse();
  }

  Future<void> _startAssistant() async {
    try {
      setState(() {
        _status = 'Controllo permessi microfono...';
      });

      final micStatus = await Permission.microphone.request();

      if (!micStatus.isGranted) {
        if (!mounted) return;
        setState(() {
          _assistantState = AssistantState.stopped;
          _status = 'Permesso microfono non concesso.';
        });
        return;
      }

      await _controller.start();
    } catch (e, st) {
      debugPrint('ERRORE AVVIO ASSISTENTE: $e');
      debugPrintStack(stackTrace: st);

      if (!mounted) return;
      setState(() {
        _assistantState = AssistantState.stopped;
        _status = 'Errore avvio assistente: $e';
      });
    }
  }

  Future<void> _stopAssistant() async {
    try {
      await _controller.stopAll();
    } catch (e, st) {
      debugPrint('ERRORE STOP ASSISTENTE: $e');
      debugPrintStack(stackTrace: st);

      if (!mounted) return;
      setState(() {
        _status = 'Errore stop assistente: $e';
      });
    }
  }

  Future<void> _restartAssistant() async {
    try {
      await _controller.stopAll();
      await Future.delayed(const Duration(milliseconds: 300));
      await _startAssistant();
    } catch (e, st) {
      debugPrint('ERRORE RIAVVIO ASSISTENTE: $e');
      debugPrintStack(stackTrace: st);

      if (!mounted) return;
      setState(() {
        _assistantState = AssistantState.stopped;
        _status = 'Errore riavvio assistente: $e';
      });
    }
  }

  Color _stateColor() {
    switch (_assistantState) {
      case AssistantState.idleWakeWord:
        return const Color(0xFF9FE8FF);
      case AssistantState.listeningCommand:
        return const Color(0xFFFFD166);
      case AssistantState.processing:
        return const Color(0xFF7FDBFF);
      case AssistantState.speaking:
        return const Color(0xFFFF3B30);
      case AssistantState.stopped:
        return Colors.white38;
      }
  }

  String _stateLabel() {
    switch (_assistantState) {
      case AssistantState.idleWakeWord:
        return 'IN ATTESA';
      case AssistantState.listeningCommand:
        return 'TI ASCOLTO';
      case AssistantState.processing:
        return 'ELABORO';
      case AssistantState.speaking:
        return 'PARLO';
      case AssistantState.stopped:
        return 'FERMO';
    }
  }

  String _stateHint() {
    switch (_assistantState) {
      case AssistantState.idleWakeWord:
        return 'Di "Ehi Odin"';
      case AssistantState.listeningCommand:
        return 'Pronuncia il comando';
      case AssistantState.processing:
        return 'Sto preparando la risposta';
      case AssistantState.speaking:
        return 'Sto rispondendo';
      case AssistantState.stopped:
        return 'Premi Avvia per ripartire';
    }
  }

  IconData _stateIcon() {
    switch (_assistantState) {
      case AssistantState.idleWakeWord:
        return Icons.hearing;
      case AssistantState.listeningCommand:
        return Icons.mic;
      case AssistantState.processing:
        return Icons.psychology_alt;
      case AssistantState.speaking:
        return Icons.volume_up;
      case AssistantState.stopped:
        return Icons.mic_off;
    }
  }

  @override
  void dispose() {
    _statusSub?.cancel();
    _partialSub?.cancel();
    _finalSub?.cancel();
    _stateSub?.cancel();
    _controller.dispose();
    _speakController.dispose();
    _listenController.dispose();
    _blinkController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (kUseVisualAvatarUi) {
      return _buildVisualUi();
    }
    return _buildDebugUi();
  }

  Widget _buildVisualUi() {
    final color = _stateColor();

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(
              child: CustomPaint(
                painter: _NoirBackgroundPainter(accent: color),
              ),
            ),
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.black,
                      Colors.black,
                      color.withOpacity(0.05),
                      Colors.black,
                    ],
                  ),
                ),
              ),
            ),
            Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  AnimatedBuilder(
                    animation: Listenable.merge([
                      _speakController,
                      _listenController,
                      _blinkController,
                    ]),
                    builder: (context, _) {
                      return _EyesWidget(
                        state: _assistantState,
                        accent: color,
                        speakValue: _speakController.value,
                        listenValue: _listenController.value,
                        blinkValue: _blinkController.value,
                        diabolikStyle: kUseDiabolikStyle,
                      );
                    },
                  ),
                  const SizedBox(height: 34),
                  Text(
                    _stateLabel(),
                    style: TextStyle(
                      color: color,
                      fontSize: 30,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 3,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: Text(
                      _stateHint(),
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 16,
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: Text(
                      _status,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white54,
                        fontSize: 13,
                      ),
                    ),
                  ),
                  const SizedBox(height: 28),
                  _VisualTranscriptCard(
                    title: 'Parziale',
                    value: _partialText,
                  ),
                  const SizedBox(height: 12),
                  _VisualTranscriptCard(
                    title: 'Finale',
                    value: _finalText,
                  ),
                ],
              ),
            ),
            Positioned(
              left: 16,
              right: 16,
              bottom: 16,
              child: Wrap(
                spacing: 10,
                runSpacing: 10,
                alignment: WrapAlignment.center,
                children: [
                  _GlassButton(
                    icon: Icons.play_arrow,
                    label: 'Avvia',
                    enabled: _assistantState == AssistantState.stopped,
                    onTap: _startAssistant,
                  ),
                  _GlassButton(
                    icon: Icons.stop,
                    label: 'Ferma',
                    enabled: _assistantState != AssistantState.stopped,
                    onTap: _stopAssistant,
                  ),
                  _GlassButton(
                    icon: Icons.refresh,
                    label: 'Riavvia',
                    enabled: true,
                    onTap: _restartAssistant,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDebugUi() {
    final color = _stateColor();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Odin Assistant'),
        centerTitle: true,
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 250),
                width: double.infinity,
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: color.withOpacity(0.10),
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: color.withOpacity(0.45), width: 2),
                  boxShadow: [
                    BoxShadow(
                      color: color.withOpacity(0.12),
                      blurRadius: 12,
                      spreadRadius: 1,
                    ),
                  ],
                ),
                child: Column(
                  children: [
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 250),
                      width: 96,
                      height: 96,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: color.withOpacity(0.15),
                        border: Border.all(
                          color: color.withOpacity(0.35),
                          width: 2,
                        ),
                      ),
                      child: Icon(
                        _stateIcon(),
                        size: 44,
                        color: color,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      _stateLabel(),
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.bold,
                        color: color,
                        letterSpacing: 0.8,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _stateHint(),
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 16),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      _status,
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 14),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              _InfoCard(
                title: 'Wake word',
                value: 'Ehi Odin',
                icon: Icons.record_voice_over,
              ),
              const SizedBox(height: 12),
              _InfoCard(
                title: 'Parziale',
                value: _partialText.isEmpty ? '...' : _partialText,
                icon: Icons.graphic_eq,
              ),
              const SizedBox(height: 12),
              _InfoCard(
                title: 'Finale',
                value: _finalText.isEmpty ? '...' : _finalText,
                icon: Icons.notes,
              ),
              const SizedBox(height: 12),
              _InfoCard(
                title: 'Suggerimento',
                value: 'Durante "Ti ascolto" puoi dire anche "annulla".',
                icon: Icons.info_outline,
              ),
              const SizedBox(height: 20),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                alignment: WrapAlignment.center,
                children: [
                  ElevatedButton.icon(
                    onPressed: _assistantState == AssistantState.stopped
                        ? _startAssistant
                        : null,
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('Avvia'),
                  ),
                  ElevatedButton.icon(
                    onPressed: _assistantState != AssistantState.stopped
                        ? _stopAssistant
                        : null,
                    icon: const Icon(Icons.stop),
                    label: const Text('Ferma'),
                  ),
                  ElevatedButton.icon(
                    onPressed: _restartAssistant,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Riavvia'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EyesWidget extends StatelessWidget {
  const _EyesWidget({
    required this.state,
    required this.accent,
    required this.speakValue,
    required this.listenValue,
    required this.blinkValue,
    required this.diabolikStyle,
  });

  final AssistantState state;
  final Color accent;
  final double speakValue;
  final double listenValue;
  final double blinkValue;
  final bool diabolikStyle;

  @override
  Widget build(BuildContext context) {
    final bool isSpeaking = state == AssistantState.speaking;
    final bool isListening = state == AssistantState.listeningCommand;
    final bool isProcessing = state == AssistantState.processing;
    final bool isStopped = state == AssistantState.stopped;
    final bool isIdle = state == AssistantState.idleWakeWord;

    final double blinkScale = 1.0 - (blinkValue * 0.94);

    double eyeHeight = 24;
    double eyeWidth = 132;
    double pupilShift = 0;
    double glow = 24;
    double tilt = 0.22;
    double breathing = 0.0;

    Color eyeAccent = accent;

    if (isIdle) {
      eyeHeight = 22;
      eyeWidth = 136;
      glow = 18;
      tilt = 0.26;
      breathing = 0.5 + (listenValue * 0.5);
    } else if (isListening) {
      eyeHeight = 30 + (listenValue * 5);
      eyeWidth = 138;
      pupilShift = (listenValue - 0.5) * 8;
      glow = 28;
      tilt = 0.22;
    } else if (isProcessing) {
      eyeHeight = 16 + (listenValue * 3);
      eyeWidth = 128;
      glow = 20;
      tilt = 0.30;
      eyeAccent = Colors.lightBlueAccent;
    } else if (isSpeaking) {
      eyeHeight = 18 + (speakValue * 16);
      eyeWidth = 144;
      pupilShift = math.sin(speakValue * math.pi * 2) * 4;
      glow = 34;
      tilt = 0.18;
      eyeAccent = Colors.redAccent;
    } else if (isStopped) {
      eyeHeight = 8;
      eyeWidth = 110;
      glow = 8;
      tilt = 0.32;
      eyeAccent = Colors.white38;
    }

    eyeHeight *= blinkScale;

    return Column(
      children: [
        AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 26),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(32),
            color: Colors.white.withOpacity(0.015),
            border: Border.all(
              color: eyeAccent.withOpacity(0.14),
              width: 1.2,
            ),
            boxShadow: [
              BoxShadow(
                color: eyeAccent.withOpacity(0.06),
                blurRadius: 40,
                spreadRadius: 3,
              ),
            ],
          ),
          child: Column(
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 220),
                width: 300 + (breathing * 4),
                height: 8,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(99),
                  gradient: LinearGradient(
                    colors: [
                      Colors.transparent,
                      eyeAccent.withOpacity(0.12),
                      Colors.transparent,
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 18),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _SingleEye(
                    width: eyeWidth,
                    height: eyeHeight,
                    accent: eyeAccent,
                    pupilShift: -pupilShift,
                    glow: glow,
                    tilt: tilt,
                    diabolikStyle: diabolikStyle,
                  ),
                  const SizedBox(width: 20),
                  _SingleEye(
                    width: eyeWidth,
                    height: eyeHeight,
                    accent: eyeAccent,
                    pupilShift: pupilShift,
                    glow: glow,
                    tilt: -tilt,
                    diabolikStyle: diabolikStyle,
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _SingleEye extends StatelessWidget {
  const _SingleEye({
    required this.width,
    required this.height,
    required this.accent,
    required this.pupilShift,
    required this.glow,
    required this.tilt,
    required this.diabolikStyle,
  });

  final double width;
  final double height;
  final Color accent;
  final double pupilShift;
  final double glow;
  final double tilt;
  final bool diabolikStyle;

  @override
  Widget build(BuildContext context) {
    final safeHeight = height < 3 ? 3.0 : height;

    return Transform.rotate(
      angle: diabolikStyle ? tilt : 0,
      child: SizedBox(
        width: width,
        height: 86,
        child: Center(
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            width: width,
            height: safeHeight,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.only(
                topLeft: Radius.circular(diabolikStyle ? 4 : width / 2),
                bottomLeft: Radius.circular(width / 2),
                topRight: Radius.circular(width / 2),
                bottomRight: Radius.circular(diabolikStyle ? 4 : width / 2),
              ),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Colors.white,
                  Colors.white.withOpacity(0.88),
                ],
              ),
              boxShadow: [
                BoxShadow(
                  color: accent.withOpacity(0.38),
                  blurRadius: glow,
                  spreadRadius: 2,
                ),
                BoxShadow(
                  color: Colors.white.withOpacity(0.18),
                  blurRadius: 8,
                  spreadRadius: 0.5,
                ),
              ],
            ),
            child: ClipPath(
              clipper: diabolikStyle ? _DiabolikEyeClipper() : null,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Positioned.fill(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Colors.black.withOpacity(0.08),
                            Colors.transparent,
                            Colors.transparent,
                            Colors.black.withOpacity(0.06),
                          ],
                        ),
                      ),
                    ),
                  ),
                  Transform.translate(
                    offset: Offset(pupilShift, 0),
                    child: Container(
                      width: safeHeight * 0.42,
                      height: safeHeight * 0.42,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.black.withOpacity(0.94),
                        boxShadow: [
                          BoxShadow(
                            color: accent.withOpacity(0.25),
                            blurRadius: 6,
                            spreadRadius: 0.5,
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DiabolikEyeClipper extends CustomClipper<Path> {
  @override
  Path getClip(Size size) {
    final p = Path();

    p.moveTo(0, size.height * 0.62);
    p.quadraticBezierTo(
      size.width * 0.18,
      size.height * 0.08,
      size.width * 0.82,
      size.height * 0.18,
    );
    p.quadraticBezierTo(
      size.width * 0.96,
      size.height * 0.22,
      size.width,
      size.height * 0.44,
    );
    p.quadraticBezierTo(
      size.width * 0.84,
      size.height * 0.90,
      size.width * 0.18,
      size.height * 0.80,
    );
    p.quadraticBezierTo(
      size.width * 0.04,
      size.height * 0.76,
      0,
      size.height * 0.62,
    );
    p.close();

    return p;
  }

  @override
  bool shouldReclip(covariant CustomClipper<Path> oldClipper) => false;
}

class _VisualTranscriptCard extends StatelessWidget {
  const _VisualTranscriptCard({
    required this.title,
    required this.value,
  });

  final String title;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 320,
      constraints: const BoxConstraints(minHeight: 64),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.05),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white.withOpacity(0.10)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 12,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            value.isEmpty ? '...' : value,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 15,
            ),
          ),
        ],
      ),
    );
  }
}

class _GlassButton extends StatelessWidget {
  const _GlassButton({
    required this.icon,
    required this.label,
    required this.enabled,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool enabled;
  final Future<void> Function() onTap;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: enabled ? 1 : 0.45,
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(18),
        child: Ink(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.06),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: Colors.white.withOpacity(0.10)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: Colors.white),
              const SizedBox(width: 8),
              Text(
                label,
                style: const TextStyle(color: Colors.white),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _InfoCard extends StatelessWidget {
  const _InfoCard({
    required this.title,
    required this.value,
    required this.icon,
  });

  final String title;
  final String value;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: Theme.of(context).dividerColor,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  value,
                  style: const TextStyle(fontSize: 15),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _NoirBackgroundPainter extends CustomPainter {
  _NoirBackgroundPainter({required this.accent});

  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    final bg = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          Color(0xFF020202),
          Color(0xFF050505),
          Color(0xFF000000),
        ],
      ).createShader(Offset.zero & size);

    canvas.drawRect(Offset.zero & size, bg);

    final centerGlow = Paint()
      ..shader = RadialGradient(
        colors: [
          accent.withOpacity(0.10),
          accent.withOpacity(0.04),
          Colors.transparent,
        ],
      ).createShader(
        Rect.fromCircle(
          center: Offset(size.width / 2, size.height * 0.42),
          radius: size.width * 0.48,
        ),
      );

    canvas.drawCircle(
      Offset(size.width / 2, size.height * 0.42),
      size.width * 0.48,
      centerGlow,
    );

    final slashPaint = Paint()
      ..color = Colors.white.withOpacity(0.03)
      ..strokeWidth = 1.2;

    for (int i = -2; i < 8; i++) {
      final startY = size.height * 0.16 + (i * 80);
      canvas.drawLine(
        Offset(size.width * 0.08, startY),
        Offset(size.width * 0.92, startY + 36),
        slashPaint,
      );
    }

    final vignette = Paint()
      ..shader = RadialGradient(
        colors: [
          Colors.transparent,
          Colors.black.withOpacity(0.05),
          Colors.black.withOpacity(0.42),
        ],
        stops: const [0.55, 0.78, 1.0],
      ).createShader(Offset.zero & size);

    canvas.drawRect(Offset.zero & size, vignette);
  }

  @override
  bool shouldRepaint(covariant _NoirBackgroundPainter oldDelegate) {
    return oldDelegate.accent != accent;
  }
}
