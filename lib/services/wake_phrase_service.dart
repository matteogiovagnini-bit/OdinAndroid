import 'dart:async';

import 'package:vosk_flutter_service/vosk_flutter.dart';

import 'vosk_json.dart';
import 'vosk_model_manager.dart';

class WakePhraseService {
  final StreamController<void> _wakeController =
      StreamController<void>.broadcast();

  Stream<void> get onWakeDetected => _wakeController.stream;

  final VoskFlutterPlugin _vosk = VoskFlutterPlugin.instance();

  Recognizer? _recognizer;
  SpeechService? _speechService;

  bool _initialized = false;
  bool _running = false;

  DateTime? _lastWakeAt;

  Future<void> init() async {
    if (_initialized) return;

    final model = await VoskModelManager.instance.getModel();

    _recognizer = await _vosk.createRecognizer(
      model: model,
      sampleRate: 16000,
      grammar: const [
        'ehi odin',
        'hey odin',
      ],
    );

    _speechService = await _vosk.initSpeechService(_recognizer!);

    // IMPORTANTE:
    // niente wake sui partial, troppo instabili e generano falsi positivi

    _speechService!.onResult().listen((raw) {
      final text = extractVoskText(raw).toLowerCase().trim();

      if (_isWakePhrase(text) && !_isInCooldown()) {
        _lastWakeAt = DateTime.now();
        _wakeController.add(null);
      }
    });

    _initialized = true;
  }

  bool _isWakePhrase(String text) {
    final clean = text.trim();

    return clean == 'ehi odin' ||
        clean == 'hey odin' ||
        clean == 'ei odin' ||
        clean == 'hei odin';
  }

  bool _isInCooldown() {
    if (_lastWakeAt == null) return false;
    final diff = DateTime.now().difference(_lastWakeAt!);
    return diff.inMilliseconds < 1800;
  }

  Future<void> start() async {
    if (!_initialized) {
      await init();
    }
    if (_running) return;

    await _speechService!.start();
    _running = true;
  }

  Future<void> stop() async {
    if (!_running) return;

    await _speechService?.stop();
    _running = false;
  }

  Future<void> dispose() async {
    await stop();

    await _speechService?.dispose();
    _speechService = null;

    await _recognizer?.dispose();
    _recognizer = null;

    _initialized = false;
    _running = false;
  }

  Future<void> close() async {
    await dispose();
    await _wakeController.close();
  }
}
