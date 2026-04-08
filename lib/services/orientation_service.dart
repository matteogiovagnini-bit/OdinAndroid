// lib/services/orientation_service.dart
//
// Legge Pitch / Roll / Yaw da Android via EventChannel nativo,
// applica calibrazione/orientamento landscape,
// espone uno stream locale a Flutter
// e invia tutto all'ESP32 via HTTP POST /api/orientation.
//
// Novità rispetto alla versione precedente:
//   • gimbalEnable(bool)  → POST /api/gimbal/enable
//   • gimbalSetTarget(pitch, roll) → POST /api/gimbal/target
//   • gimbalHome()        → POST /api/gimbal/home
//   • _sendGimbalEnabled  → flag: invia dati solo se il gimbal è abilitato
//     (ma la calibrazione e lo stream locale restano sempre attivi)
//
// Dipendenze pubspec.yaml:
//   http: ^1.2.0

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

  /// Valori già calibrati (quelli che arrivano all'ESP32)
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
  // ── Configurazione sensori Android ────────────────────────
  static const EventChannel _orientationChannel =
      EventChannel('odin/orientation_stream');

  // ── Configurazione ESP32 ──────────────────────────────────
  static String _baseUrl = 'http://odin.local';
  static const String _orientationEndpoint = '/api/orientation';
  static const String _gimbalEnableEndpoint = '/api/gimbal/enable';
  static const String _gimbalTargetEndpoint = '/api/gimbal/target';
  static const String _gimbalHomeEndpoint   = '/api/gimbal/home';

  // ── Configurazione invio ──────────────────────────────────
  /// Intervallo minimo tra un POST e il successivo.
  static const Duration _sendInterval = Duration(milliseconds: 100);

  /// Deadband: non inviare se la variazione è inferiore a N gradi.
  static const double _deadband = 0.3;

  // ── Calibrazione montaggio telefono ──────────────────────
  //
  // Remap Android usato: AXIS_X, AXIS_Z  (originale in MainActivity.kt)
  //
  // Valori raw misurati con il telefono in posizione di riposo
  // sul gimbal (landscape, display verso il BASSO):
  //
  //   pitch raw ≈  -87.6°   → vogliamo  0°  → pitchOffset = +90°
  //   roll  raw ≈ -169.3°   → vogliamo  0°  → rollSign=+1, rollTrim=+180°
  //   yaw   raw = libero    → nessun offset
  //
  // Risultato atteso dopo calibrazione in posizione di riposo:
  //   pitch cal ≈ -87.6 + 90.0       = +2.4°  ≈ 0° ✅
  //   roll  cal ≈ (-169.3*1) + 180.0 = +10.7° ≈ 0° ✅
  //   (normalizeAngleDeg gestisce i valori oltre ±180°)
  //
  // Se dopo la messa in opera i segni risultano invertiti:
  //   pitch rovesciato → _pitchOffset = -90.0
  //   roll  rovesciato → _rollSign    = -1.0
  //
  static const LandscapeSide _landscapeSide = LandscapeSide.left; // informativo

  // Pitch: raw ≈ -88° a riposo → offset +90° → calibrato ≈ 0°
  static const double _pitchOffset = 90.0;
  static const double _pitchTrim   =  0.0;

  // Roll: raw ≈ -169° a riposo → *+1 +180° → calibrato ≈ +11° ≈ 0°
  static const double _rollSign    =  1.0;
  static const double _rollTrim    = 180.0;

  static const double _yawSign     =  1.0;
  static const double _yawTrim     =  0.0;

  // ── Stato interno ─────────────────────────────────────────
  StreamSubscription<dynamic>? _nativeOrientationSub;
  Timer? _sendTimer;
  http.Client? _httpClient;

  double _pitch = 0.0;
  double _roll  = 0.0;
  double _yaw   = 0.0;

  double _lastSentPitch = double.infinity;
  double _lastSentRoll  = double.infinity;
  double _lastSentYaw   = double.infinity;

  bool _running = false;

  /// Quando true, il servizio invia i dati all'ESP32.
  /// Rimane false finché il gimbal non viene abilitato esplicitamente.
  bool _sendingToEsp32 = false;

  // ── Stream pubblico ───────────────────────────────────────
  final _controller = StreamController<OrientationData>.broadcast();
  Stream<OrientationData> get stream => _controller.stream;

  OrientationData get current => OrientationData(
        pitch: _pitch,
        roll:  _roll,
        yaw:   _yaw,
        calibratedPitch: _getCalibratedPitch(_pitch),
        calibratedRoll:  _getCalibratedRoll(_roll),
        calibratedYaw:   _getCalibratedYaw(_yaw),
      );

  bool get isSendingToEsp32 => _sendingToEsp32;

  // ── API pubblica ──────────────────────────────────────────
  static void setBaseUrl(String url) => _baseUrl = url;

  void start() {
    if (_running) return;
    _running = true;

    _httpClient = http.Client();

    _nativeOrientationSub = _orientationChannel
        .receiveBroadcastStream()
        .listen(
          _onNativeOrientation,
          onError: (Object e) {
            debugPrint('[OrientationService] Errore stream: $e');
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

  // ── Comandi gimbal ────────────────────────────────────────

  /// Abilita o disabilita il gimbal sull'ESP32.
  /// Se abilitato, avvia automaticamente l'invio dei dati di orientamento.
  Future<bool> gimbalEnable(bool enabled) async {
    final ok = await _postJson(_gimbalEnableEndpoint, {'enabled': enabled});
    if (ok) {
      _sendingToEsp32 = enabled;
      // Reset deadband per forzare un invio immediato
      _lastSentPitch = double.infinity;
      _lastSentRoll  = double.infinity;
      _lastSentYaw   = double.infinity;
      debugPrint('[OrientationService] Gimbal ${enabled ? "abilitato" : "disabilitato"}');
    }
    return ok;
  }

  /// Imposta il target di posa (pitch/roll) sull'ESP32.
  Future<bool> gimbalSetTarget(double pitch, double roll) async {
    return _postJson(_gimbalTargetEndpoint, {
      'pitch': pitch,
      'roll':  roll,
    });
  }

  /// Porta il gimbal in home.
  Future<bool> gimbalHome() async {
    try {
      if (_httpClient == null) return false;
      final resp = await _httpClient!
          .post(Uri.parse('$_baseUrl$_gimbalHomeEndpoint'))
          .timeout(const Duration(seconds: 3));
      return resp.statusCode == 200;
    } catch (e) {
      debugPrint('[OrientationService] gimbalHome errore: $e');
      return false;
    }
  }

  // ── Ricezione dati dal layer nativo ──────────────────────
  void _onNativeOrientation(dynamic event) {
    try {
      final map = Map<dynamic, dynamic>.from(event as Map);
      _pitch = _toDouble(map['pitch']);
      _roll  = _toDouble(map['roll']);
      _yaw   = _normalizeAngleDeg(_toDouble(map['yaw']));

      if (!_controller.isClosed) {
        _controller.add(OrientationData(
          pitch: _pitch,
          roll:  _roll,
          yaw:   _yaw,
          calibratedPitch: _getCalibratedPitch(_pitch),
          calibratedRoll:  _getCalibratedRoll(_roll),
          calibratedYaw:   _getCalibratedYaw(_yaw),
        ));
      }
    } catch (e) {
      debugPrint('[OrientationService] Errore parsing orientation event: $e');
    }
  }

  // ── Calibrazione ──────────────────────────────────────────
  double _getCalibratedPitch(double rawPitch) =>
      _normalizeAngleDeg(rawPitch + _pitchOffset + _pitchTrim);

  double _getCalibratedRoll(double rawRoll) =>
      _normalizeAngleDeg((rawRoll * _rollSign) + _rollTrim);

  double _getCalibratedYaw(double rawYaw) =>
      _normalizeAngleDeg((rawYaw * _yawSign) + _yawTrim);

  // ── Invio HTTP (throttled + deadband) ────────────────────
  Future<void> _trySend() async {
    // Invia solo se il gimbal è abilitato e il client è pronto
    if (!_running || !_sendingToEsp32 || _httpClient == null) return;

    final sendPitch = _getCalibratedPitch(_pitch);
    final sendRoll  = _getCalibratedRoll(_roll);
    final sendYaw   = _getCalibratedYaw(_yaw);

    final deltaPitch = (sendPitch - _lastSentPitch).abs();
    final deltaRoll  = (sendRoll  - _lastSentRoll).abs();
    final deltaYaw   = _angularDeltaDeg(sendYaw, _lastSentYaw);

    if (deltaPitch < _deadband &&
        deltaRoll  < _deadband &&
        deltaYaw   < _deadband) {
      return;
    }

    _lastSentPitch = sendPitch;
    _lastSentRoll  = sendRoll;
    _lastSentYaw   = sendYaw;

    try {
      await _httpClient!
          .post(
            Uri.parse('$_baseUrl$_orientationEndpoint'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'pitch': sendPitch,
              'roll':  sendRoll,
              'yaw':   sendYaw,
            }),
          )
          .timeout(const Duration(milliseconds: 300));
    } on Exception catch (e) {
      debugPrint('[OrientationService] Errore invio: $e');
    }
  }

  // ── Helper JSON POST ──────────────────────────────────────
  Future<bool> _postJson(String endpoint, Map<String, dynamic> body) async {
    try {
      final client = _httpClient ?? http.Client();
      final resp = await client
          .post(
            Uri.parse('$_baseUrl$endpoint'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 3));
      return resp.statusCode == 200;
    } catch (e) {
      debugPrint('[OrientationService] POST $endpoint errore: $e');
      return false;
    }
  }

  // ── Utility ──────────────────────────────────────────────
  double _toDouble(dynamic value) {
    if (value is double) return value;
    if (value is int)    return value.toDouble();
    if (value is num)    return value.toDouble();
    return double.tryParse(value.toString()) ?? 0.0;
  }

  double _normalizeAngleDeg(double angle) {
    var a = angle % 360.0;
    if (a >  180.0) a -= 360.0;
    if (a < -180.0) a += 360.0;
    return a;
  }

  double _angularDeltaDeg(double a, double b) {
    if (a.isInfinite || b.isInfinite) return double.infinity;
    final diff = (a - b).abs() % 360.0;
    return diff > 180.0 ? 360.0 - diff : diff;
  }
}
