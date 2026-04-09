import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

class CameraService {
  CameraController? _controller;
  bool _isInitialized = false;
  bool _isStreaming = false;
  Timer? _streamingTimer;
  http.Client? _streamClient;
  String? _streamUrl;

  bool get isInitialized => _isInitialized;
  bool get isStreaming => _isStreaming;
  CameraController? get controller => _controller;

  Future<void> initialize() async {
    if (_isInitialized) return;

    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        debugPrint('[Camera] No cameras available');
        return;
      }

      final frontCamera = cameras.firstWhere(
        (cam) => cam.lensDirection == CameraLensDirection.front,
        orElse: () => cameras.first,
      );

      debugPrint('[Camera] Using: ${frontCamera.name}');

      _controller = CameraController(
        frontCamera,
        ResolutionPreset.medium,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );

      await _controller!.initialize();
      _isInitialized = true;
      debugPrint('[Camera] Initialized successfully');
    } catch (e, st) {
      debugPrint('[Camera] Error initializing: $e');
      debugPrintStack(stackTrace: st);
      _isInitialized = false;
    }
  }

  Future<void> dispose() async {
    await stopVideoStream();
    if (_controller != null) {
      if (_controller!.value.isInitialized) {
        await _controller!.dispose();
      }
      _controller = null;
      _isInitialized = false;
      debugPrint('[Camera] Disposed');
    }
  }

  Future<void> startVideoStream(String url) async {
    if (_isStreaming) return;
    if (!_isInitialized || _controller == null) {
      debugPrint('[CameraStream] Camera not initialized, initializing...');
      await initialize();
      if (!_isInitialized) {
        debugPrint('[CameraStream] Failed to initialize camera');
        return;
      }
    }

    _streamUrl = url;
    _streamClient = http.Client();
    _isStreaming = true;

    _captureAndSendLoop();

    debugPrint('[CameraStream] Started streaming to $url');
  }

  Future<void> stopVideoStream() async {
    if (!_isStreaming) return;

    _isStreaming = false;

    _streamClient?.close();
    _streamClient = null;
    _streamUrl = null;

    debugPrint('[CameraStream] Stopped streaming');
  }

  Future<void> _captureAndSendLoop() async {
    while (_isStreaming) {
      await _captureAndSendFrame();
      await Future.delayed(const Duration(milliseconds: 150));
    }
  }

  Future<void> _captureAndSendFrame() async {
    if (!_isStreaming || _streamClient == null || _streamUrl == null) return;
    if (_controller == null || !_controller!.value.isInitialized) return;

    try {
      final XFile frame = await _controller!.takePicture();
      final List<int> bytes = await File(frame.path).readAsBytes();

      try {
        final resp = await _streamClient!
            .post(
              Uri.parse(_streamUrl!),
              headers: {'Content-Type': 'image/jpeg'},
              body: bytes,
            )
            .timeout(const Duration(milliseconds: 500));
        if (resp.statusCode != 200) {
          debugPrint('[CameraStream] Frame sent, status: ${resp.statusCode}');
        }
      } on Exception catch (e) {
        debugPrint('[CameraStream] Error sending frame: $e');
      }
    } catch (e) {
      debugPrint('[CameraStream] Error capturing frame: $e');
    }
  }
}
