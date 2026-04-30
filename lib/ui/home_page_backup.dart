import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:camera/camera.dart';
import 'package:nfc_manager/nfc_manager.dart';

import '../services/assistant_service.dart';
import '../services/camera_service.dart';
import '../services/orientation_service.dart';
import '../services/tts_service.dart';
import '../services/vosk_command_service.dart';
import '../services/wake_phrase_service.dart';
import '../services/voice_assistant_controller.dart';
import '../widgets/animated_eyes.dart';

const bool kUseVisualAvatarUi = true;
const bool kUseDiabolikStyle = false;

// ── NFC ──────────────────────────────────────────────────
const String kAllowedNfcTagId = '04:73:6C:7A:9A:3D:80';

// ── Odin Home: indirizzo Raspberry Pi ───────────────────────────
const String kEsp32BaseUrl = 'http://jarvis';

// ── Gimbal: target di posa iniziale ──────────────────────────
const double kGimbalTargetPitch = -8.0;
const double kGimbalTargetRoll  =  0.0;

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with TickerProviderStateMixin {
  late final VoiceAssistantController _controller;
  late final OrientationService _orientationService;

  StreamSubscription<OrientationData>? _orientationSub;

  double _pitch = 0;
  double _roll = 0;
  double _yaw = 0;
  double _calibratedPitch = 0;
  double _calibratedRoll = 0;
  double _calibratedYaw = 0;
  String _orientationLabel = 'N/A';

  StreamSubscription<String>? _statusSub;
  StreamSubscription<String>? _partialSub;
  StreamSubscription<String>? _finalSub;
  StreamSubscription<AssistantState>? _stateSub;

  String _status = 'Avvio assistente...';
  String _partialText = '';
  String _finalText = '';
  String _nfcStatus = 'Avvicina il tag NFC autorizzato';
  AssistantState _assistantState = AssistantState.stopped;

  late final AnimationController _speakController;
  late final AnimationController _listenController;
  late final AnimationController _blinkController;

  final CameraService _cameraService = CameraService();

  bool _nfcSessionRunning = false;
  bool _nfcUnlocking = false;

  @override
  void initState() {
    super.initState();

    _speakController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 420),
    );
    _listenController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
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

    OrientationService.setBaseUrl(kEsp32BaseUrl);
    _orientationService = OrientationService();

    _statusSub = _controller.statusStream.listen((value) {
      if (!mounted) return;
      setState(() => _status = value);
    });

    _partialSub = _controller.partialStream.listen((value) {
      if (!mounted) return;
      setState(() => _partialText = value);
    });

    _finalSub = _controller.finalStream.listen((value) {
      if (!mounted) return;
      setState(() => _finalText = value);
    });

    _stateSub = _controller.stateStream.listen((value) {
      if (!mounted) return;
      setState(() => _assistantState = value);
      _updateAnimationsForState(value);
    });

    _orientationSub = _orientationService.stream.listen((data) {
      if (!mounted) return;
      setState(() {
        _pitch = data.pitch;
        _roll = data.roll;
        _yaw = data.yaw;
        _calibratedPitch = data.calibratedPitch;
        _calibratedRoll = data.calibratedRoll;
        _calibratedYaw = data.calibratedYaw;
        _orientationLabel = 'P:${_pitch.toStringAsFixed(1)}° R:${_roll.toStringAsFixed(1)}° Y:${_yaw.toStringAsFixed(1)}°';
      });
    });

    _startNfcGateMode();
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
        _blinkController.stop();
        break;
    }
  }

  Future<void> _scheduleBlink() async {
    if (!mounted) return;
    if (_assistantState != AssistantState.idleWakeWord) {
      await Future.delayed(const Duration(seconds: 3));
      if (mounted) _scheduleBlink();
      return;
    }

    await _blinkController.forward();
    await _blinkController.reverse();

    await Future.delayed(Duration(milliseconds: 2000 + math.Random().nextInt(4000)));
    if (mounted) _scheduleBlink();
  }

  String _getEmotionForState(AssistantState state) {
    switch (state) {
      case AssistantState.idleWakeWord:
        return 'neutral';
      case AssistantState.listeningCommand:
        return 'happy';
      case AssistantState.processing:
        return 'thinking';
      case AssistantState.speaking:
        return 'happy';
      case AssistantState.stopped:
        return 'neutral';
    }
  }

  double get _currentPitch => _pitch - _calibratedPitch;
  double get _currentRoll => _roll - _calibratedRoll;
  double get _currentYaw => _yaw - _calibratedYaw;

  // ── NFC Gate ──────────────────────────────────────────────

  Future<void> _startNfcGateMode() async {
    try {
      await _controller.stopAll();
    } catch (_) {}

    await _stopNfcSession();

    if (!mounted) return;
    setState(() {
      _assistantState = AssistantState.stopped;
      _status = 'Assistente fermo. Attesa tag NFC autorizzato...';
      _nfcStatus = 'Controllo disponibilità NFC...';
      _partialText = '';
      _finalText = '';
    });

    final micStatus = await Permission.microphone.request();
    if (!micStatus.isGranted) {
      if (!mounted) return;
      setState(() {
        _status = 'Permesso microfono non concesso.';
        _nfcStatus = 'Impossibile avviare assistente.';
      });
      return;
    }

    final camStatus = await Permission.camera.request();
    if (!camStatus.isGranted) {
      debugPrint('[Camera] Camera permission not granted, continuing without camera');
    }

    final available = await NfcManager.instance.isAvailable();
    if (!available) {
      if (!mounted) return;
      setState(() {
        _status = 'NFC non disponibile su questo dispositivo.';
        _nfcStatus = 'NFC non disponibile.';
      });
      return;
    }

    if (!mounted) return;
    setState(() => _nfcStatus = 'Avvicina il tag NFC autorizzato');

    await _startNfcSession();
  }

  Future<void> _startNfcSession() async {
    if (_nfcSessionRunning) return;
    _nfcSessionRunning = true;
    _nfcUnlocking = false;

    await NfcManager.instance.startSession(
      pollingOptions: {
        NfcPollingOption.iso14443,
        NfcPollingOption.iso15693,
        NfcPollingOption.iso18092,
      },
      onDiscovered: (NfcTag tag) async {
        if (_nfcUnlocking) return;

        try {
          // DEBUG
          final scannedId = kAllowedNfcTagId;
          //final scannedId = extractTagId(tag);
          // FINE DEBUG

          if (scannedId == null || scannedId.isEmpty) {
            if (!mounted) return;
            setState(() {
              _nfcStatus = 'Tag NFC non riconosciuto/vuoto';
            });
            return;
          }

          debugPrint('[NFC] Tag letto: $scannedId');

          if (scannedId.toUpperCase() == kAllowedNfcTagId.toUpperCase()) {
            _nfcUnlocking = true;
            await _stopNfcSession();
            if (!mounted) return;
            setState(() {
              _nfcStatus = 'Tag autorizzato! Avvio assistente...';
            });
            await _startAssistant();
          } else {
            if (!mounted) return;
            setState(() {
              _nfcStatus = 'Tag non autorizzato: $scannedId';
            });
          }
        } catch (e) {
          debugPrint('[NFC] Errore: $e');
        }
      },
    );
  }

  String? _extractTagId(NfcTag tag) {
    try {
      if (tag.data is Map) {
        final data = tag.data as Map;
        if (data.containsKey('nfca')) {
          final nfca = data['nfca'];
          if (nfca != null && nfca is Map && nfca.containsKey('identifier')) {
            final id = nfca['identifier'];
            if (id is List) {
              return id.map((e) => e.toRadixString(16).padLeft(2, '0')).join(':').toUpperCase();
            }
          }
        }
      }
    } catch (e) {
      debugPrint('[NFC] Errore estrazione tag: $e');
    }
    return null;
  }

  Future<void> _stopNfcSession() async {
    try {
      await NfcManager.instance.stopSession();
    } catch (_) {}
    _nfcSessionRunning = false;
  }

  // ── Start Assistant ───────────────────────────────────────────

  Future<void> _startAssistant() async {
    try {
      setState(() {
        _status = 'Avvio assistente...';
      });

      await _controller.start();

      _cameraService.setObjectDetectorCallback((objects) {
        debugPrint('[Vision] Rilevato: $objects');
      });

      await _cameraService.startVideoStream('\$kEsp32BaseUrl/frame');

      try {
        await _orientationService.gimbalEnable(true);
        await _orientationService.gimbalSetTarget(kGimbalTargetPitch, kGimbalTargetRoll);
      } catch (e) {
        debugPrint('[Gimbal] Errore: $e');
      }

      await _controller.ttsService.speak('Sistema attivato');
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

      await _controller.ttsService.speak('Sistema attivato');
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

  Color _stateColor() {
    switch (_assistantState) {
      case AssistantState.idleWakeWord:
        return Colors.blueAccent;
      case AssistantState.listeningCommand:
        return Colors.greenAccent;
      case AssistantState.processing:
        return Colors.orangeAccent;
      case AssistantState.speaking:
        return Colors.purpleAccent;
      case AssistantState.stopped:
        return Colors.redAccent;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (kUseVisualAvatarUi) return _buildVisualUi();
    return _buildDebugUi();
  }

  Widget _buildVisualUi() {
    final AssistantState visualState = _assistantState;
    final Color accent = _stateColor();

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 350),
                child: CustomPaint(
                  painter: _NoirBackgroundPainter(
                    accent: accent,
                    state: visualState,
                  ),
                ),
              ),
            ),
            Center(
              child: AnimatedBuilder(
                animation: Listenable.merge([
                  _speakController,
                  _listenController,
                  _blinkController,
                ]),
                builder: (context, _) {
                  return AnimatedEyesWidget(
                    pitch: _currentPitch,
                    roll: _currentRoll,
                    yaw: _currentYaw,
                    isListening: visualState == AssistantState.listeningCommand,
                    isSpeaking: visualState == AssistantState.speaking,
                    emotion: _getEmotionForState(visualState),
                  );
                },
              ),
            ),
            if (_cameraService.isInitialized && 
                _cameraService.controller != null && 
                _cameraService.controller!.value.isInitialized)
              Positioned(
                right: 16,
                bottom: 16,
                child: Container(
                  width: MediaQuery.of(context).size.width * 1 / 6,
                  height: MediaQuery.of(context).size.height * 1 / 6,
                  decoration: BoxDecoration(
                    border: Border.all(color: accent.withValues(alpha: 0.4), width: 2),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: CameraPreview(_cameraService.controller!),
                ),
              )
            else
              Positioned(
                right: 16,
                bottom: 16,
                child: Container(
                  width: MediaQuery.of(context).size.width * 1 / 6,
                  height: MediaQuery.of(context).size.height * 1 / 6,
                  decoration: BoxDecoration(
                    color: Colors.grey.withValues(alpha: 0.3),
                    border: Border.all(color: accent.withValues(alpha: 0.4), width: 2),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Center(
                    child: Icon(Icons.camera_alt, color: Colors.white54, size: 32),
                  ),
                ),
              ),
            Positioned(
              left: 16,
              bottom: 16,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _nfcStatus,
                    style: TextStyle(color: Colors.white.withValues(alpha: 0.7), fontSize: 12),
                  ),
                  Text(
                    _status,
                    style: TextStyle(color: accent.withValues(alpha: 0.9), fontSize: 14, fontWeight: FontWeight.bold),
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
                  color: color.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: color.withValues(alpha: 0.45), width: 2),
                ),
                child: Column(
                  children: [
                    AnimatedContainer(
                        duration: const Duration(milliseconds: 250),
                        width: 96,
                        height: 96,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: color.withValues(alpha: 0.15),
                          border: Border.all(color: color.withValues(alpha: 0.35), width: 2),
                        ),
                        child: Icon(_stateIcon(), size: 44, color: color)),
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
                    Text(_stateHint(), textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 16)),
                    const SizedBox(height: 10),
                    Text(_status, textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 14)),
                    const SizedBox(height: 8),
                    Text(_nfcStatus, textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 12)),
                    const SizedBox(height: 8),
                    Text(_orientationLabel, textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 12)),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              if (_partialText.isNotEmpty)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.blue.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text('Parziale: $_partialText',
                      style: const TextStyle(fontSize: 14))),
              if (_finalText.isNotEmpty)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.green.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text('Comando: $_finalText',
                      style: const TextStyle(fontSize: 14))),
            ],
          ),
        ),
      ),
    );
  }

  IconData _stateIcon() {
    switch (_assistantState) {
      case AssistantState.idleWakeWord:
        return Icons.hearing;
      case AssistantState.listeningCommand:
        return Icons.mic;
      case AssistantState.processing:
        return Icons.psychology;
      case AssistantState.speaking:
        return Icons.volume_up;
      case AssistantState.stopped:
        return Icons.error_outline;
    }
  }

  String _stateLabel() {
    switch (_assistantState) {
      case AssistantState.idleWakeWord:
        return 'In attesa...';
      case AssistantState.listeningCommand:
        return 'Ascolto...';
      case AssistantState.processing:
        return 'Elaboro...';
      case AssistantState.speaking:
        return 'Parlo...';
      case AssistantState.stopped:
        return 'Fermo';
    }
  }

  String _stateHint() {
    switch (_assistantState) {
      case AssistantState.idleWakeWord:
        return 'Di "Ehi Odin" per attivare';
      case AssistantState.listeningCommand:
        return 'Pronuncia un comando';
      case AssistantState.processing:
        return 'Sto elaborando la richiesta...';
      case AssistantState.speaking:
        return 'Risposta in corso...';
      case AssistantState.stopped:
        return 'Assistente non attivo';
    }
  }

  @override
  void dispose() {
    _statusSub?.cancel();
    _partialSub?.cancel();
    _finalSub?.cancel();
    _stateSub?.cancel();
    _orientationSub?.cancel();
    _stopNfcSession();
    _orientationService.dispose();
    _controller.dispose();
    _speakController.dispose();
    _listenController.dispose();
    _blinkController.dispose();
    _cameraService.dispose();
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    super.dispose();
  }
}

class _NoirBackgroundPainter extends CustomPainter {
  final Color accent;
  final AssistantState state;

  _NoirBackgroundPainter({required this.accent, required this.state});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.black
      ..style = PaintingStyle.fill;
    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, size.height), paint);

    if (state == AssistantState.idleWakeWord || state == AssistantState.listeningCommand) {
      final pulsePaint = Paint()
        ..color = accent.withValues(alpha: 0.03)
        ..style = PaintingStyle.fill;
      final center = Offset(size.width / 2, size.height / 2);
      canvas.drawCircle(center, size.width * 0.4, pulsePaint);
    }
  }

  @override
  bool shouldRepaint(covariant _NoirBackgroundPainter old) {
    return old.accent != accent || old.state != state;
  }
}
