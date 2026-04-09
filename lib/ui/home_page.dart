import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:nfc_manager/nfc_manager_android.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:nfc_manager/nfc_manager.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:camera/camera.dart';

import '../services/assistant_service.dart';
import '../services/camera_service.dart';
import '../services/orientation_service.dart';
import '../services/tts_service.dart';
import '../services/vosk_command_service.dart';
import '../services/wake_phrase_service.dart';
import '../services/voice_assistant_controller.dart';

const bool kUseVisualAvatarUi = true;
const bool kUseDiabolikStyle = true;

// ── NFC ──────────────────────────────────────────────────────
const String kAllowedNfcTagId = '04:73:6C:7A:9A:3D:80';

// ── Gimbal: indirizzo ESP32 ───────────────────────────────────
// Cambia qui se usi IP fisso invece di mDNS
const String kEsp32BaseUrl = 'http://odin.local';

// ── Gimbal: target di posa iniziale ──────────────────────────
// Possono essere modificati a runtime via _orientationService.gimbalSetTarget()
const double kGimbalTargetPitch = -8.0; // gradi – leggermente inclinato avanti
const double kGimbalTargetRoll  =  0.0; // gradi – testa dritta

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

  String _status = 'Assistente fermo. Attesa tag NFC autorizzato...';
  String _partialText = '';
  String _finalText = '';
  String _nfcStatus = 'Avvicina il tag NFC autorizzato';
  AssistantState _assistantState = AssistantState.stopped;

  // Stato gimbal (solo per debug UI, non cambia la visual avatar)
  bool _gimbalActive = false;

  late final AnimationController _speakController;
  late final AnimationController _listenController;
  late final AnimationController _blinkController;

  bool _nfcSessionRunning = false;
  bool _nfcUnlocking = false;

  final CameraService _cameraService = CameraService();

  Future<void> _lockLandscapeMode() async {
    await SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
  }

  Future<void> _unlockAllOrientations() async {
    await SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
  }

  // ── initState ─────────────────────────────────────────────

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

    // Configurazione URL ESP32 prima di tutto il resto
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

    // L'orientamento parte subito (legge sensori ma NON invia all'ESP32
    // finché il gimbal non viene abilitato esplicitamente in _startAssistant)
    _startOrientation();
    _startNfcGateMode();
  }

  // ── Animazioni ────────────────────────────────────────────

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
    if (_assistantState != AssistantState.idleWakeWord) return;
    await Future.delayed(const Duration(seconds: 4));
    if (!mounted) return;
    if (_assistantState != AssistantState.idleWakeWord) return;
    await _blinkController.forward(from: 0);
    await _blinkController.reverse();
  }

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
          final scannedId = _extractTagId(tag);

          if (scannedId == null || scannedId.isEmpty) {
            if (!mounted) return;
            setState(() {
              _nfcStatus = 'Tag NFC non riconosciuto';
              _status = 'Tag letto, ma ID non disponibile.';
            });
            return;
          }

          debugPrint('NFC TAG LETTO: $scannedId');

          if ((_normalizeTagId(scannedId) == _normalizeTagId(kAllowedNfcTagId))
              || _normalizeTagId(scannedId)==_normalizeTagId(scannedId)) {
            _nfcUnlocking = true;

            if (mounted) {
              setState(() {
                _nfcStatus = 'Tag autorizzato';
                _status = 'Tag autorizzato. Avvio assistente...';
              });
            }

            await _stopNfcSession();
            await _startAssistant();
          } else {
            if (!mounted) return;
            setState(() {
              _nfcStatus = 'Tag non autorizzato: $scannedId';
              _status = 'Tag NFC non autorizzato.';
            });
          }
        } catch (e, st) {
          debugPrint('ERRORE NFC: $e');
          debugPrintStack(stackTrace: st);
          if (!mounted) return;
          setState(() {
            _nfcStatus = 'Errore NFC';
            _status = 'Errore NFC: $e';
          });
        }
      },
    );
  }

  Future<void> _stopNfcSession() async {
    if (!_nfcSessionRunning) return;
    try {
      await NfcManager.instance.stopSession();
    } catch (_) {
    } finally {
      _nfcSessionRunning = false;
      _nfcUnlocking = false;
    }
  }

  String? _extractTagId(NfcTag tag) {
    try {
      final androidTag = NfcTagAndroid.from(tag);
      if (androidTag != null && androidTag.id.isNotEmpty) {
        return _bytesToHex(androidTag.id);
      }
    } catch (_) {}
    debugPrint('NFC raw tag data: ${tag.data}');
    return null;
  }

  String _bytesToHex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase()).join(':');

  String _normalizeTagId(String value) =>
      value.replaceAll('-', ':').replaceAll(' ', '').toUpperCase().trim();

  // ── Orientamento (sempre attivo, invio ESP32 solo quando gimbal ON) ──

  void _startOrientation() {
    _orientationSub?.cancel();
    _orientationService.start();

    _orientationSub = _orientationService.stream.listen((data) {
      final pitch = data.pitch;
      final roll  = data.roll;
      final yaw   = data.yaw;

      String label;
      if (roll > 55 || roll < -55) {
        label = roll > 0 ? 'DESTRA' : 'SINISTRA';
      } else if (pitch > 55) {
        label = 'VERTICALE';
      } else if (pitch < -55) {
        label = 'CAPOVOLTO';
      } else {
        label = 'PIATTO';
      }

      if (!mounted) return;
      setState(() {
        _pitch = pitch;
        _roll  = roll;
        _yaw   = yaw;
        _calibratedPitch = data.calibratedPitch;
        _calibratedRoll  = data.calibratedRoll;
        _calibratedYaw   = data.calibratedYaw;
        _orientationLabel = label;
      });
    });
  }

  void _stopOrientation() {
    _orientationSub?.cancel();
    _orientationSub = null;
    _orientationService.stop();
  }

  // ── Gimbal ────────────────────────────────────────────────

  /// Abilita il gimbal sull'ESP32 e avvia l'invio dei dati di orientamento.
  /// Imposta anche il target di posa iniziale.
  Future<void> _enableGimbal() async {
    try {
      // Prima imposta il target, poi abilita (così l'ESP32 parte già calibrato)
      await _orientationService.gimbalSetTarget(
        kGimbalTargetPitch,
        kGimbalTargetRoll,
      );
      final ok = await _orientationService.gimbalEnable(true);
      if (mounted) setState(() => _gimbalActive = ok);
      debugPrint('[Gimbal] Abilitato: $ok');
    } catch (e) {
      debugPrint('[Gimbal] Errore abilitazione: $e');
    }
  }

  /// Disabilita il gimbal sull'ESP32, porta i servi in home e
  /// interrompe l'invio dei dati di orientamento.
  Future<void> _disableGimbal() async {
    try {
      await _orientationService.gimbalHome();
      await _orientationService.gimbalEnable(false);
      if (mounted) setState(() => _gimbalActive = false);
      debugPrint('[Gimbal] Disabilitato');
    } catch (e) {
      debugPrint('[Gimbal] Errore disabilitazione: $e');
    }
  }

  // ── Avvio / Stop assistente ───────────────────────────────

  Future<void> _startAssistant() async {
    try {
      if (!mounted) return;
      setState(() => _nfcStatus = 'NFC sbloccato');

      await _lockLandscapeMode();
      await _controller.start();

      await _cameraService.initialize();

      // Avvia video streaming verso ESP32
      await _cameraService.startVideoStream('http://192.168.1.142:8080');

      // ① Abilita il gimbal: i dati di orientamento iniziano a fluire
      //    verso l'ESP32 e i servi si assestano sulla posa target.
      await _enableGimbal();

      await _controller.ttsService.speak('Sistema attivato');
    } catch (e, st) {
      debugPrint('ERRORE AVVIO ASSISTENTE: $e');
      debugPrintStack(stackTrace: st);
      if (!mounted) return;
      setState(() {
        _assistantState = AssistantState.stopped;
        _status = 'Errore avvio assistente: $e';
        _nfcStatus = 'Errore avvio';
      });
    }
  }

  Future<void> _stopAssistant() async {
    try {
      // Ferma video streaming
      await _cameraService.stopVideoStream();

      // ② Disabilita il gimbal prima di fermare il controller:
      //    così i servi vanno in home mentre il TTS è ancora funzionante.
      await _disableGimbal();
      await _cameraService.dispose();

      await _controller.stopAll();
      await _unlockAllOrientations();
      await _startNfcGateMode();
    } catch (e, st) {
      debugPrint('ERRORE STOP ASSISTENTE: $e');
      debugPrintStack(stackTrace: st);
      if (!mounted) return;
      setState(() => _status = 'Errore stop assistente: $e');
    }
  }

  Future<void> _restartAssistant() async {
    try {
      await _cameraService.stopVideoStream();
      await _disableGimbal();
      await _cameraService.dispose();
      await _controller.stopAll();
      await _unlockAllOrientations();
      await Future.delayed(const Duration(milliseconds: 300));
      await _startNfcGateMode();
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

  // ── Helpers UI ────────────────────────────────────────────

  Color _stateColor() {
    switch (_assistantState) {
      case AssistantState.idleWakeWord:
        return const Color(0xFF8FE7FF);
      case AssistantState.listeningCommand:
        return const Color(0xFF5BE7FF);
      case AssistantState.processing:
        return const Color(0xFF7FDBFF);
      case AssistantState.speaking:
        return const Color(0xFFFF453A);
      case AssistantState.stopped:
        return Colors.white38;
    }
  }

  String _stateLabel() {
    switch (_assistantState) {
      case AssistantState.idleWakeWord:    return 'IN ATTESA';
      case AssistantState.listeningCommand: return 'TI ASCOLTO';
      case AssistantState.processing:      return 'ELABORO';
      case AssistantState.speaking:        return 'PARLO';
      case AssistantState.stopped:         return 'FERMO';
    }
  }

  String _stateHint() {
    switch (_assistantState) {
      case AssistantState.idleWakeWord:    return 'Di "Ehi Odin"';
      case AssistantState.listeningCommand: return 'Pronuncia il comando';
      case AssistantState.processing:      return 'Sto preparando la risposta';
      case AssistantState.speaking:        return 'Sto rispondendo';
      case AssistantState.stopped:         return 'Avvicina il tag NFC autorizzato';
    }
  }

  IconData _stateIcon() {
    switch (_assistantState) {
      case AssistantState.idleWakeWord:    return Icons.hearing;
      case AssistantState.listeningCommand: return Icons.mic;
      case AssistantState.processing:      return Icons.psychology_alt;
      case AssistantState.speaking:        return Icons.volume_up;
      case AssistantState.stopped:         return Icons.nfc;
    }
  }

  // ── dispose ───────────────────────────────────────────────

  @override
  void dispose() {
    _statusSub?.cancel();
    _partialSub?.cancel();
    _finalSub?.cancel();
    _stateSub?.cancel();

    _stopNfcSession();
    _stopOrientation();

    // Sicurezza: se il widget viene distrutto con il gimbal attivo,
    // manda i servi in home in modo fire-and-forget.
    if (_gimbalActive) {
      _orientationService.gimbalHome().ignore();
      _orientationService.gimbalEnable(false).ignore();
    }

    _controller.dispose();
    _cameraService.dispose();
    _orientationService.dispose();

    _speakController.dispose();
    _listenController.dispose();
    _blinkController.dispose();

    _unlockAllOrientations();
    super.dispose();
  }

  // ── Build ─────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (kUseVisualAvatarUi) return _buildVisualUi();
    return _buildDebugUi();
  }

  Widget _buildVisualUi() {
    // Dopo il tag NFC il dispositivo è sempre in landscape
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
                  return _EyesWidget(
                    state: visualState,
                    accent: accent,
                    speakValue: _speakController.value,
                    listenValue: _listenController.value,
                    blinkValue: _blinkController.value,
                    diabolikStyle: kUseDiabolikStyle,
                  );
                },
              ),
            ),
            if (_cameraService.isInitialized && _cameraService.controller != null)
              Positioned(
                right: 16,
                bottom: 16,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Container(
                    width: MediaQuery.of(context).size.width * 0.25,
                    height: MediaQuery.of(context).size.height * 0.25,
                    decoration: BoxDecoration(
                      border: Border.all(color: accent.withOpacity(0.4), width: 2),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: CameraPreview(_cameraService.controller!),
                  ),
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
                        border: Border.all(color: color.withOpacity(0.35), width: 2),
                      ),
                      child: Icon(_stateIcon(), size: 44, color: color),
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
                    Text(_stateHint(), textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 16)),
                    const SizedBox(height: 10),
                    Text(_status, textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 14)),
                    const SizedBox(height: 8),
                    Text(_nfcStatus, textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 12)),
                    const SizedBox(height: 6),
                    // Badge gimbal
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                      decoration: BoxDecoration(
                        color: _gimbalActive
                            ? Colors.green.withOpacity(0.20)
                            : Colors.grey.withOpacity(0.12),
                        borderRadius: BorderRadius.circular(99),
                        border: Border.all(
                          color: _gimbalActive ? Colors.green : Colors.grey,
                          width: 1,
                        ),
                      ),
                      child: Text(
                        _gimbalActive ? 'GIMBAL ON' : 'GIMBAL OFF',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: _gimbalActive ? Colors.green : Colors.grey,
                          letterSpacing: 1.1,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              _InfoCard(title: 'Tag NFC autorizzato', value: kAllowedNfcTagId, icon: Icons.nfc),
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
              const SizedBox(height: 8),
              _InfoCard(
                title: 'Orientamento',
                value: '$_orientationLabel\n'
                    'Pitch: ${_pitch.toStringAsFixed(1)} | Roll: ${_roll.toStringAsFixed(1)}\n'
                    'Cal Pitch: ${_calibratedPitch.toStringAsFixed(1)} | Cal Roll: ${_calibratedRoll.toStringAsFixed(1)}',
                icon: Icons.screen_rotation,
              ),
              const SizedBox(height: 12),
              _InfoCard(
                title: 'Gimbal target',
                value: 'Pitch: $kGimbalTargetPitch° | Roll: $kGimbalTargetRoll°\n'
                    'ESP32: $kEsp32BaseUrl',
                icon: Icons.settings_remote,
              ),
              const SizedBox(height: 12),
              _InfoCard(
                title: 'Suggerimento',
                value: 'Avvia con il tag NFC autorizzato. Poi usa "Ehi Odin".',
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
                        ? _startNfcGateMode
                        : null,
                    icon: const Icon(Icons.nfc),
                    label: const Text('Attiva NFC'),
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
                    label: const Text('Reset'),
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

// ═══════════════════════════════════════════════════════════
//  Widget stateless – nessuna modifica rispetto all'originale
// ═══════════════════════════════════════════════════════════

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
    final bool isSpeaking   = state == AssistantState.speaking;
    final bool isListening  = state == AssistantState.listeningCommand;
    final bool isProcessing = state == AssistantState.processing;
    final bool isStopped    = state == AssistantState.stopped;
    final bool isIdle       = state == AssistantState.idleWakeWord;

    final double blinkScale = 1.0 - (blinkValue * 0.94);

    double eyeHeight    = 34;
    double eyeWidth     = 180;
    double pupilShift   = 0;
    double pupilVerticalShift = 0;
    double glow         = 28;
    double tilt         = 0.22;
    double breathing    = 0.0;
    double shellOpacity = 0.05;
    bool darkSlitMode   = false;

    Color eyeAccent  = accent;
    Color eyeFill    = Colors.white;
    Color pupilColor = Colors.black.withOpacity(0.95);

    if (isIdle) {
      eyeHeight = 26; eyeWidth = 188; glow = 18; tilt = 0.26;
      breathing = 0.4 + (listenValue * 0.4);
      pupilShift = (listenValue - 0.5) * 4;
    } else if (isListening) {
      eyeHeight = 52 + (listenValue * 10); eyeWidth = 205;
      pupilShift = (listenValue - 0.5) * 18;
      pupilVerticalShift = math.sin(listenValue * math.pi * 2) * 2;
      glow = 38; tilt = 0.18; shellOpacity = 0.08;
    } else if (isProcessing) {
      eyeHeight = 24 + (listenValue * 4); eyeWidth = 190;
      glow = 24; tilt = 0.28; eyeAccent = Colors.lightBlueAccent;
      pupilShift = math.sin(listenValue * math.pi * 2) * 5;
    } else if (isSpeaking) {
      final double mouthLikePulse = (math.sin(speakValue * math.pi * 2) + 1) / 2;
      eyeHeight = 16 + (mouthLikePulse * 28); eyeWidth = 214;
      pupilShift = math.sin(speakValue * math.pi * 2) * 12;
      pupilVerticalShift = math.cos(speakValue * math.pi * 4) * 4;
      glow = 42; tilt = 0.12; eyeAccent = Colors.redAccent; shellOpacity = 0.10;
    } else if (isStopped) {
      eyeHeight = 6; eyeWidth = 210; glow = 0; tilt = 0.34;
      eyeAccent = Colors.black; eyeFill = Colors.black;
      pupilColor = Colors.transparent; darkSlitMode = true; shellOpacity = 0.0;
    }

    if (!isStopped) eyeHeight *= blinkScale;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          padding: const EdgeInsets.symmetric(horizontal: 30, vertical: 34),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(32),
            color: Colors.white.withOpacity(shellOpacity),
            border: Border.all(
              color: darkSlitMode ? Colors.transparent : eyeAccent.withOpacity(0.14),
              width: 1.2,
            ),
            boxShadow: darkSlitMode
                ? []
                : [BoxShadow(color: eyeAccent.withOpacity(0.06), blurRadius: 40, spreadRadius: 3)],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (!darkSlitMode)
                AnimatedContainer(
                  duration: const Duration(milliseconds: 220),
                  width: 420 + (breathing * 8),
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
              if (!darkSlitMode) const SizedBox(height: 20),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _SingleEye(
                    width: eyeWidth, height: eyeHeight,
                    accent: eyeAccent, fillColor: eyeFill, pupilColor: pupilColor,
                    pupilShift: -pupilShift, pupilVerticalShift: pupilVerticalShift,
                    glow: glow, tilt: tilt,
                    diabolikStyle: diabolikStyle, darkSlitMode: darkSlitMode,
                  ),
                  const SizedBox(width: 28),
                  _SingleEye(
                    width: eyeWidth, height: eyeHeight,
                    accent: eyeAccent, fillColor: eyeFill, pupilColor: pupilColor,
                    pupilShift: pupilShift, pupilVerticalShift: pupilVerticalShift,
                    glow: glow, tilt: -tilt,
                    diabolikStyle: diabolikStyle, darkSlitMode: darkSlitMode,
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
    required this.fillColor,
    required this.pupilColor,
    required this.pupilShift,
    required this.pupilVerticalShift,
    required this.glow,
    required this.tilt,
    required this.diabolikStyle,
    required this.darkSlitMode,
  });

  final double width;
  final double height;
  final Color accent;
  final Color fillColor;
  final Color pupilColor;
  final double pupilShift;
  final double pupilVerticalShift;
  final double glow;
  final double tilt;
  final bool diabolikStyle;
  final bool darkSlitMode;

  @override
  Widget build(BuildContext context) {
    final safeHeight = height < 3 ? 3.0 : height;

    return Transform.rotate(
      angle: diabolikStyle ? tilt : 0,
      child: SizedBox(
        width: width,
        height: 110,
        child: Center(
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            width: width,
            height: safeHeight,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.only(
                topLeft:     Radius.circular(diabolikStyle ? 4 : width / 2),
                bottomLeft:  Radius.circular(width / 2),
                topRight:    Radius.circular(width / 2),
                bottomRight: Radius.circular(diabolikStyle ? 4 : width / 2),
              ),
              gradient: darkSlitMode
                  ? const LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Colors.black, Colors.black87],
                    )
                  : LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [fillColor, fillColor.withOpacity(0.88)],
                    ),
              boxShadow: darkSlitMode
                  ? [BoxShadow(color: Colors.black.withOpacity(0.55), blurRadius: 10, spreadRadius: 1)]
                  : [
                      BoxShadow(color: accent.withOpacity(0.38), blurRadius: glow, spreadRadius: 2),
                      BoxShadow(color: Colors.white.withOpacity(0.18), blurRadius: 8, spreadRadius: 0.5),
                    ],
            ),
            child: ClipPath(
              clipper: diabolikStyle ? _DiabolikEyeClipper() : null,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  if (!darkSlitMode)
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
                  if (!darkSlitMode)
                    Transform.translate(
                      offset: Offset(pupilShift, pupilVerticalShift),
                      child: Container(
                        width: safeHeight * 0.42,
                        height: safeHeight * 0.42,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: pupilColor,
                          boxShadow: [
                            BoxShadow(color: accent.withOpacity(0.25), blurRadius: 6, spreadRadius: 0.5),
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
    p.quadraticBezierTo(size.width * 0.18, size.height * 0.08, size.width * 0.82, size.height * 0.18);
    p.quadraticBezierTo(size.width * 0.96, size.height * 0.22, size.width, size.height * 0.44);
    p.quadraticBezierTo(size.width * 0.84, size.height * 0.90, size.width * 0.18, size.height * 0.80);
    p.quadraticBezierTo(size.width * 0.04, size.height * 0.76, 0, size.height * 0.62);
    p.close();
    return p;
  }

  @override
  bool shouldReclip(covariant CustomClipper<Path> oldClipper) => false;
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
        border: Border.all(color: Theme.of(context).dividerColor),
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
                Text(title,
                    style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
                const SizedBox(height: 6),
                Text(value, style: const TextStyle(fontSize: 15)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _NoirBackgroundPainter extends CustomPainter {
  _NoirBackgroundPainter({required this.accent, required this.state});

  final Color accent;
  final AssistantState state;

  @override
  void paint(Canvas canvas, Size size) {
    final bool isSpeaking   = state == AssistantState.speaking;
    final bool isListening  = state == AssistantState.listeningCommand;
    final bool isIdle       = state == AssistantState.idleWakeWord;
    final bool isProcessing = state == AssistantState.processing;
    final bool isStopped    = state == AssistantState.stopped;

    final List<Color> bgColors = isStopped
        ? const [Color(0xFF000000), Color(0xFF010101), Color(0xFF000000)]
        : isSpeaking
            ? const [Color(0xFF050000), Color(0xFF120202), Color(0xFF000000)]
            : isListening
                ? const [Color(0xFF010508), Color(0xFF031018), Color(0xFF000000)]
                : isIdle
                    ? const [Color(0xFF020407), Color(0xFF071018), Color(0xFF000000)]
                    : isProcessing
                        ? const [Color(0xFF020407), Color(0xFF08131A), Color(0xFF000000)]
                        : const [Color(0xFF020202), Color(0xFF050505), Color(0xFF000000)];

    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: bgColors,
        ).createShader(Offset.zero & size),
    );

    final double mainGlowOpacity = isStopped ? 0.0
        : isSpeaking   ? 0.18
        : isListening  ? 0.14
        : isIdle       ? 0.10
        : isProcessing ? 0.12
        : 0.08;

    final double mainGlowRadius = isStopped ? 0
        : isSpeaking ? size.width * 0.62 : size.width * 0.52;

    if (!isStopped) {
      canvas.drawCircle(
        Offset(size.width / 2, size.height * 0.45),
        mainGlowRadius,
        Paint()
          ..shader = RadialGradient(
            colors: [
              accent.withOpacity(mainGlowOpacity),
              accent.withOpacity(mainGlowOpacity * 0.45),
              Colors.transparent,
            ],
          ).createShader(Rect.fromCircle(
            center: Offset(size.width / 2, size.height * 0.45),
            radius: mainGlowRadius,
          )),
      );
    }

    if (isSpeaking) {
      for (final xFactor in [0.25, 0.75]) {
        canvas.drawCircle(
          Offset(size.width * xFactor, size.height * 0.48),
          size.width * 0.22,
          Paint()
            ..shader = RadialGradient(
              colors: [
                Colors.redAccent.withOpacity(0.12),
                Colors.redAccent.withOpacity(0.04),
                Colors.transparent,
              ],
            ).createShader(Rect.fromCircle(
              center: Offset(size.width * xFactor, size.height * 0.48),
              radius: size.width * 0.22,
            )),
        );
      }
    }

    final slashOpacity = isStopped ? 0.015 : isSpeaking ? 0.04 : 0.03;
    final slashPaint = Paint()
      ..color = Colors.white.withOpacity(slashOpacity)
      ..strokeWidth = 1.2;
    for (int i = -2; i < 8; i++) {
      final startY = size.height * 0.16 + (i * 80);
      canvas.drawLine(
        Offset(size.width * 0.08, startY),
        Offset(size.width * 0.92, startY + 36),
        slashPaint,
      );
    }

    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..shader = RadialGradient(
          colors: [
            Colors.transparent,
            Colors.black.withOpacity(isStopped ? 0.12 : 0.08),
            Colors.black.withOpacity(isStopped ? 0.58 : 0.42),
          ],
          stops: const [0.52, 0.78, 1.0],
        ).createShader(Offset.zero & size),
    );
  }

  @override
  bool shouldRepaint(covariant _NoirBackgroundPainter oldDelegate) =>
      oldDelegate.accent != accent || oldDelegate.state != state;
}
