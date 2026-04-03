// lib/services/orientation_service.dart
//
// Legge Pitch / Roll / Yaw da Android via EventChannel nativo,
// applica calibrazione/orientamento landscape,
// espone uno stream locale a Flutter
// e invia tutto all'ESP32 via HTTP POST.
//
// Dipendenze pubspec.yaml:
//   http: ^1.2.0
//
// Note:
// - Yaw arriva dal layer nativo Android tramite EventChannel
// - Pitch/Roll/Yaw locali (raw) restano disponibili nello stream
// - I valori inviati all'ESP32 vengono calibrati prima del POST

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

enum LandscapeSide { right, left }

class OrientationData {
  /// Valori raw letti dai sensori / layer nativo
  final double pitch;
  final double roll;
  final double yaw;

  /// Valori già calibrati per ESP32
  final double calibratedPitch;
  final double calibratedRoll;
  final double calibratedYaw;

  const OrientationData({
    required this.pitch,
    required this.roll,
    required this.yaw,
    required this.calibratedPitch,
    required this.calibratedRoll,
    required this.calibratedYaw,
  });

  @override
  String toString() =>
      'OrientationData('
      'pitch: ${pitch.toStringAsFixed(1)}°, '
      'roll: ${roll.toStringAsFixed(1)}°, '
      'yaw: ${yaw.toStringAsFixed(1)}°, '
      'calPitch: ${calibratedPitch.toStringAsFixed(1)}°, '
      'calRoll: ${calibratedRoll.toStringAsFixed(1)}°, '
      'calYaw: ${calibratedYaw.toStringAsFixed(1)}°'
      ')';
}

class OrientationService {
  // ── Configurazione sensori Android ───────────────────────
  static const EventChannel _orientationChannel =
      EventChannel('odin/orientation_stream');

  // ── Configurazione ESP32 ─────────────────────────────────
  static String _baseUrl = 'http://odin.local';
  static const String _endpoint = '/api/orientation';

  // ── Configurazione invio ─────────────────────────────────
  static const Duration _sendInterval = Duration(milliseconds: 100);
  static const double _deadband = 0.3;

  // ── Configurazione montaggio telefono ────────────────────
  //
  // LandscapeSide.right:
  //   pitch grezzo ≈ +90° a riposo → offset -90°
  //
  // LandscapeSide.left:
  //   pitch grezzo ≈ -90° a riposo → offset +90°
  //
  static const LandscapeSide _landscapeSide = LandscapeSide.left;

  static double get _pitchOffset =>
      _landscapeSide == LandscapeSide.right ? -90.0 : 90.0;

  // ── Calibrazione fine ────────────────────────────────────
  static const double _pitchTrim = 0.0;

  /// 1.0 = normale, -1.0 = invertito
  static const double _rollSign = 1.0;
  static const double _rollTrim = 0.0;

  /// Se vuoi invertire lo yaw cambia a -1.0
  static const double _yawSign = 1.0;
  static const double _yawTrim = 0.0;

  // ── Stato interno ────────────────────────────────────────
  StreamSubscription<dynamic>? _nativeOrientationSub;
  Timer? _sendTimer;
  http.Client? _httpClient;

  double _pitch = 0.0;
  double _roll = 0.0;
  double _yaw = 0.0;

  double _lastSentPitch = double.infinity;
  double _lastSentRoll = double.infinity;
  double _lastSentYaw = double.infinity;

  bool _running = false;

  // ── Stream pubblico ──────────────────────────────────────
  final _controller = StreamController<OrientationData>.broadcast();
  Stream<OrientationData> get stream => _controller.stream;

  OrientationData get current => OrientationData(
        pitch: _pitch,
        roll: _roll,
        yaw: _yaw,
        calibratedPitch: _getCalibratedPitch(_pitch),
        calibratedRoll: _getCalibratedRoll(_roll),
        calibratedYaw: _getCalibratedYaw(_yaw),
      );

  // ── API pubblica ─────────────────────────────────────────
  static void setBaseUrl(String url) => _baseUrl = url;

  void start() {
    if (_running) return;
    _running = true;

    _httpClient = http.Client();

    _nativeOrientationSub = _orientationChannel.receiveBroadcastStream().listen(
      _onNativeOrientation,
      onError: (Object e) {
        debugPrint('[OrientationService] Errore stream orientamento: $e');
      },
    );

    _sendTimer = Timer.periodic(_sendInterval, (_) => _trySend());

    debugPrint('[OrientationService] Avviato');
  }

  void stop() {
    if (!_running) return;
    _running = false;

    _nativeOrientationSub?.cancel();
    _nativeOrientationSub = null;

    _sendTimer?.cancel();
    _sendTimer = null;

    _httpClient?.close();
    _httpClient = null;

    debugPrint('[OrientationService] Fermato');
  }

  void dispose() {
    stop();
    _controller.close();
  }

  // ── Ricezione dati dal layer nativo ──────────────────────
  void _onNativeOrientation(dynamic event) {
    try {
      final map = Map<dynamic, dynamic>.from(event as Map);

      _pitch = _toDouble(map['pitch']);
      _roll = _toDouble(map['roll']);
      _yaw = _normalizeAngleDeg(_toDouble(map['yaw']));

      if (!_controller.isClosed) {
        _controller.add(
          OrientationData(
            pitch: _pitch,
            roll: _roll,
            yaw: _yaw,
            calibratedPitch: _getCalibratedPitch(_pitch),
            calibratedRoll: _getCalibratedRoll(_roll),
            calibratedYaw: _getCalibratedYaw(_yaw),
          ),
        );
      }
    } catch (e) {
      debugPrint('[OrientationService] Errore parsing orientation event: $e');
    }
  }

  // ── Calibrazione ─────────────────────────────────────────
  double _getCalibratedPitch(double rawPitch) {
    return _normalizeAngleDeg(rawPitch + _pitchOffset + _pitchTrim);
  }

  double _getCalibratedRoll(double rawRoll) {
    return _normalizeAngleDeg((rawRoll * _rollSign) + _rollTrim);
  }

  double _getCalibratedYaw(double rawYaw) {
    return _normalizeAngleDeg((rawYaw * _yawSign) + _yawTrim);
  }

  // ── Invio HTTP (throttled + deadband) ────────────────────
  Future<void> _trySend() async {
    if (!_running || _httpClient == null) return;

    final sendPitch = _getCalibratedPitch(_pitch);
    final sendRoll = _getCalibratedRoll(_roll);
    final sendYaw = _getCalibratedYaw(_yaw);

    final deltaPitch = (sendPitch - _lastSentPitch).abs();
    final deltaRoll = (sendRoll - _lastSentRoll).abs();
    final deltaYaw = _angularDeltaDeg(sendYaw, _lastSentYaw);

    if (deltaPitch < _deadband &&
        deltaRoll < _deadband &&
        deltaYaw < _deadband) {
      return;
    }

    _lastSentPitch = sendPitch;
    _lastSentRoll = sendRoll;
    _lastSentYaw = sendYaw;

    try {
      await _httpClient!
          .post(
            Uri.parse('$_baseUrl$_endpoint'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'pitch': sendPitch,
              'roll': sendRoll,
              'yaw': sendYaw,
            }),
          )
          .timeout(const Duration(milliseconds: 300));
    } on Exception catch (e) {
      debugPrint('[OrientationService] Errore invio: $e');
    }
  }

  // ── Utility ──────────────────────────────────────────────
  double _toDouble(dynamic value) {
    if (value is double) return value;
    if (value is int) return value.toDouble();
    if (value is num) return value.toDouble();
    return double.tryParse(value.toString()) ?? 0.0;
  }

  double _normalizeAngleDeg(double angle) {
    var a = angle % 360.0;
    if (a > 180.0) a -= 360.0;
    if (a < -180.0) a += 360.0;
    return a;
  }

  double _angularDeltaDeg(double a, double b) {
    if (a.isInfinite || b.isInfinite) return double.infinity;
    final diff = (a - b).abs() % 360.0;
    return diff > 180.0 ? 360.0 - diff : diff;
  }
}

