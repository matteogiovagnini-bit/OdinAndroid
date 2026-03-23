import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:nfc_manager/nfc_manager.dart';

class NfcGateService {
  NfcGateService({
    required this.allowedTagId,
  });

  final String allowedTagId;

  final StreamController<String> _statusController =
      StreamController<String>.broadcast();

  Stream<String> get statusStream => _statusController.stream;

  bool _sessionRunning = false;

  Future<bool> isAvailable() async {
    return NfcManager.instance.isAvailable();
  }

  Future<void> startListening({
    required Future<void> Function() onAuthorizedTag,
    Future<void> Function(String scannedId)? onWrongTag,
  }) async {
    if (_sessionRunning) return;

    final available = await isAvailable();
    if (!available) {
      _statusController.add('NFC non disponibile su questo dispositivo.');
      return;
    }

    _sessionRunning = true;
    _statusController.add('Avvicina il tag NFC autorizzato...');

    await NfcManager.instance.startSession(
      onDiscovered: (NfcTag tag) async {
        try {
          final scannedId = extractTagId(tag);

          if (scannedId == null || scannedId.isEmpty) {
            _statusController.add('Tag NFC non riconosciuto.');
            return;
          }

          debugPrint('NFC TAG LETTO: $scannedId');

          if (_normalize(scannedId) == _normalize(allowedTagId)) {
            _statusController.add('Tag autorizzato.');
            await stopListening();
            await onAuthorizedTag();
          } else {
            _statusController.add('Tag non autorizzato: $scannedId');
            if (onWrongTag != null) {
              await onWrongTag(scannedId);
            }
          }
        } catch (e) {
          _statusController.add('Errore NFC: $e');
        }
      },
    );
  }

  Future<void> stopListening() async {
    if (!_sessionRunning) return;

    try {
      await NfcManager.instance.stopSession();
    } catch (_) {
      // ignora
    } finally {
      _sessionRunning = false;
    }
  }

  String? extractTagId(NfcTag tag) {
    final data = tag.data;

    if (data.containsKey('nfca')) {
      final nfca = data['nfca'];
      if (nfca is Map && nfca['identifier'] is List) {
        return _bytesToHex(List<int>.from(nfca['identifier']));
      }
    }

    if (data.containsKey('mifareclassic')) {
      final mifare = data['mifareclassic'];
      if (mifare is Map && mifare['identifier'] is List) {
        return _bytesToHex(List<int>.from(mifare['identifier']));
      }
    }

    if (data.containsKey('mifareultralight')) {
      final ultralight = data['mifareultralight'];
      if (ultralight is Map && ultralight['identifier'] is List) {
        return _bytesToHex(List<int>.from(ultralight['identifier']));
      }
    }

    if (data.containsKey('ndef')) {
      final ndef = data['ndef'];
      if (ndef is Map && ndef['identifier'] is List) {
        return _bytesToHex(List<int>.from(ndef['identifier']));
      }
    }

    return null;
  }

  String _bytesToHex(List<int> bytes) {
    return bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
        .join(':');
  }

  String _normalize(String value) {
    return value.replaceAll('-', ':').replaceAll(' ', '').toUpperCase().trim();
  }

  Future<void> dispose() async {
    await stopListening();
    await _statusController.close();
  }
}
