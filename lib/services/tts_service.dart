import 'package:flutter/services.dart';

class TtsService {
  static const MethodChannel _channel = MethodChannel('assistantapp/tts');

  Future<void> init() async {
    await _channel.invokeMethod('init');
  }

  Future<void> speak(String text) async {
    await _channel.invokeMethod('speak', {'text': text});
  }

  Future<void> stop() async {
    await _channel.invokeMethod('stop');
  }

  Future<void> dispose() async {
    await _channel.invokeMethod('dispose');
  }
}