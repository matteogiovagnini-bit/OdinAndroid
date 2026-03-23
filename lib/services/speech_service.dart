import 'dart:async';
import 'package:flutter/services.dart';

class AppSpeechService {
  static const MethodChannel _channel =
      MethodChannel('assistantapp/speech');

  final StreamController<String> _partialController =
      StreamController<String>.broadcast();
  final StreamController<String> _finalController =
      StreamController<String>.broadcast();

  Stream<String> get partialResults => _partialController.stream;
  Stream<String> get finalResults => _finalController.stream;

  bool _initialized = false;

  Future<void> init() async {
    if (_initialized) return;

    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'onPartial':
          final text = (call.arguments as String?) ?? '';
          if (text.trim().isNotEmpty) {
            _partialController.add(text);
          }
          break;
        case 'onFinal':
          final text = (call.arguments as String?) ?? '';
          if (text.trim().isNotEmpty) {
            _finalController.add(text);
          }
          break;
      }
    });

    _initialized = true;
  }

  Future<void> startListening() async {
    if (!_initialized) {
      await init();
    }
    await _channel.invokeMethod('startListening');
  }

  Future<void> stopListening() async {
    await _channel.invokeMethod('stopListening');
  }

  Future<void> dispose() async {
    await _channel.invokeMethod('disposeSpeech');
    await _partialController.close();
    await _finalController.close();
  }
}
