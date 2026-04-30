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
    Set<NfcPollingOption>? pollingOptions,
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
      pollingOptions: pollingOptions ?? {
        NfcPollingOption.iso14443,
        NfcPollingOption.iso15693,
        NfcPollingOption.iso18092,
      },
      onDiscovered: (NfcTag tag) async {
        try {
          // DEBUG
          final scannedId = _normalize(allowedTagId);
          //final scannedId = extractTagId(tag);
          // FINE DEBUG
          if (scannedId == null || scannedId.isEmpty) {
            _statusController.add('Tag NFC non riconosciuto/vuoto.');
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

  String _normalize(String value) {
    return value.replaceAll('-', ':').replaceAll(' ', '').toUpperCase().trim();
  }

  Future<void> dispose() async {
    await stopListening();
    await _statusController.close();
  }
}
