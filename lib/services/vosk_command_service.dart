import 'dart:async';

import 'package:vosk_flutter_service/vosk_flutter.dart';

import 'vosk_json.dart';
import 'vosk_model_manager.dart';

class VoskCommandService {
  final StreamController<String> _partialController =
      StreamController<String>.broadcast();
  final StreamController<String> _finalController =
      StreamController<String>.broadcast();

  Stream<String> get partialResults => _partialController.stream;
  Stream<String> get finalResults => _finalController.stream;

  final VoskFlutterPlugin _vosk = VoskFlutterPlugin.instance();

  Recognizer? _recognizer;
  SpeechService? _speechService;

  bool _initialized = false;
  bool _running = false;

  Future<void> init() async {
    if (_initialized) return;

    final model = await VoskModelManager.instance.getModel();

    _recognizer = await _vosk.createRecognizer(
      model: model,
      sampleRate: 16000,
    );

    _speechService = await _vosk.initSpeechService(_recognizer!);

    _speechService!.onPartial().listen((raw) {
      final text = extractVoskPartial(raw);
      if (text.isNotEmpty) {
        _partialController.add(text);
      }
    });

    _speechService!.onResult().listen((raw) {
      final text = extractVoskText(raw);
      if (text.isNotEmpty) {
        _finalController.add(text);
      }
    });

    _initialized = true;
  }

  Future<void> startListening() async {
    if (!_initialized) {
      await init();
    }
    if (_running) return;

    await _speechService!.start();
    _running = true;
  }

  Future<void> stopListening() async {
    if (!_running) return;

    await _speechService?.stop();
    _running = false;
  }

  Future<void> dispose() async {
    await stopListening();

    await _speechService?.dispose();
    _speechService = null;

    await _recognizer?.dispose();
    _recognizer = null;

    _initialized = false;
    _running = false;
  }

  Future<void> close() async {
    await dispose();
    await _partialController.close();
    await _finalController.close();
  }
}
