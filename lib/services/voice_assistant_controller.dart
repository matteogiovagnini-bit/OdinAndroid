import 'dart:async';

import 'package:flutter/services.dart';

import 'assistant_service.dart';
import 'tts_service.dart';
import 'vosk_command_service.dart';
import 'vosk_model_manager.dart';
import 'wake_phrase_service.dart';

enum AssistantState {
  idleWakeWord,
  listeningCommand,
  processing,
  speaking,
  stopped,
}

class VoiceAssistantController {
  VoiceAssistantController({
    required this.wakePhraseService,
    required this.commandService,
    required this.ttsService,
    required this.assistantService,
  });

  final WakePhraseService wakePhraseService;
  final VoskCommandService commandService;
  final TtsService ttsService;
  final AssistantService assistantService;

  final StreamController<AssistantState> _stateController =
      StreamController<AssistantState>.broadcast();
  final StreamController<String> _statusController =
      StreamController<String>.broadcast();
  final StreamController<String> _partialController =
      StreamController<String>.broadcast();
  final StreamController<String> _finalController =
      StreamController<String>.broadcast();

  Stream<AssistantState> get stateStream => _stateController.stream;
  Stream<String> get statusStream => _statusController.stream;
  Stream<String> get partialStream => _partialController.stream;
  Stream<String> get finalStream => _finalController.stream;

  AssistantState _state = AssistantState.stopped;
  bool _busy = false;
  bool _initialized = false;
  bool _ttsCooldownActive = false;

  StreamSubscription<void>? _wakeSub;
  StreamSubscription<String>? _partialSub;
  StreamSubscription<String>? _finalSub;

  Timer? _commandTimeout;

  Future<void> init() async {
    if (_initialized) return;

    await ttsService.init();
    await VoskModelManager.instance.getModel();

    _initialized = true;
  }

  Future<void> start() async {
    await init();
    await _startWakeMode();
  }

  Future<void> _startWakeMode() async {
    if (_ttsCooldownActive) return;

    _cancelCommandTimeout();

    await _cancelCommandSubscriptions();
    await commandService.dispose();

    await _wakeSub?.cancel();
    _wakeSub = null;

    await wakePhraseService.dispose();
    await wakePhraseService.init();

    _wakeSub = wakePhraseService.onWakeDetected.listen((_) {
      _handleWakeWordSafe();
    });

    await wakePhraseService.start();

    _setState(AssistantState.idleWakeWord);
    _statusController.add('In attesa di "Ehi Odin"...');
  }

  Future<void> _startCommandMode() async {
    _cancelCommandTimeout();

    await _wakeSub?.cancel();
    _wakeSub = null;

    await wakePhraseService.dispose();

    await commandService.init();

    await _partialSub?.cancel();
    await _finalSub?.cancel();

    _partialSub = commandService.partialResults.listen((text) {
      if (_state == AssistantState.listeningCommand) {
        _partialController.add(text);

        if (text.trim().isNotEmpty) {
          _restartCommandTimeout();
        }
      }
    });

    _finalSub = commandService.finalResults.listen((text) {
      _handleCommandSafe(text);
    });

    await commandService.startListening();

    _setState(AssistantState.listeningCommand);
    _statusController.add('Ti ascolto...');
    _partialController.add('');
    _finalController.add('');

    await _playListeningBeep();

    _restartCommandTimeout();
  }

  Future<void> _playListeningBeep() async {
    try {
      await SystemSound.play(SystemSoundType.click);
    } catch (_) {
      // ignora se il device non supporta il system click
    }
  }

  void _restartCommandTimeout() {
    _cancelCommandTimeout();
    _commandTimeout = Timer(const Duration(seconds: 8), () async {
      if (_state == AssistantState.listeningCommand && !_busy) {
        try {
          await commandService.stopListening();
          await commandService.dispose();
          _statusController.add('Nessun comando ricevuto.');
          await _startWakeMode();
        } catch (e) {
          _statusController.add('Errore timeout comando: $e');
          _setState(AssistantState.stopped);
        }
      }
    });
  }

  Future<void> _handleWakeWordSafe() async {
    try {
      await _handleWakeWord();
    } catch (e) {
      _statusController.add('Errore wake word: $e');
      _setState(AssistantState.stopped);
    }
  }

  Future<void> _handleCommandSafe(String text) async {
    try {
      await _handleCommand(text);
    } catch (e) {
      _statusController.add('Errore comando: $e');
      _setState(AssistantState.stopped);
    }
  }

  Future<void> _handleWakeWord() async {
    if (_busy || _state != AssistantState.idleWakeWord) return;
    if (_ttsCooldownActive) return;

    _busy = true;
    try {
      await ttsService.stop();
      await _startCommandMode();
    } finally {
      _busy = false;
    }
  }

  bool _isCancelCommand(String text) {
    final clean = text.toLowerCase().trim();

    return clean == 'annulla' ||
        clean == 'annulla comando' ||
        clean == 'ferma' ||
        clean == 'stop';
  }

  Future<void> _handleCommand(String text) async {
    final clean = text.trim();
    if (clean.isEmpty) return;
    if (_busy || _state != AssistantState.listeningCommand) return;

    _busy = true;
    try {
      _cancelCommandTimeout();
      _finalController.add(clean);

      await commandService.stopListening();
      await commandService.dispose();

      if (_isCancelCommand(clean)) {
        _statusController.add('Comando annullato.');
        await _startWakeMode();
        return;
      }

      _setState(AssistantState.processing);
      _statusController.add('Sto elaborando...');

      final reply = await assistantService.process(clean);

      _setState(AssistantState.speaking);
      _statusController.add('Rispondo...');

      await _speakWithCooldown(reply);

      await _startWakeMode();
    } finally {
      _busy = false;
    }
  }

  Future<void> _speakWithCooldown(String text) async {
    _ttsCooldownActive = true;

    try {
      // sicurezza: wake spenta durante il parlato
      await wakePhraseService.dispose();

      await ttsService.speak(text);

      // piccolo ritardo per evitare che gli ultimi fonemi del TTS
      // vengano catturati subito come wake word
      await Future.delayed(const Duration(milliseconds: 1200));
    } finally {
      _ttsCooldownActive = false;
    }
  }

  Future<void> stopAll() async {
    _cancelCommandTimeout();

    await _wakeSub?.cancel();
    _wakeSub = null;

    await _cancelCommandSubscriptions();

    await wakePhraseService.dispose();
    await commandService.dispose();
    await ttsService.stop();

    _ttsCooldownActive = false;

    _setState(AssistantState.stopped);
    _statusController.add('Assistente fermato.');
  }

  void _cancelCommandTimeout() {
    _commandTimeout?.cancel();
    _commandTimeout = null;
  }

  Future<void> _cancelCommandSubscriptions() async {
    await _partialSub?.cancel();
    _partialSub = null;

    await _finalSub?.cancel();
    _finalSub = null;
  }

  void _setState(AssistantState newState) {
    _state = newState;
    _stateController.add(newState);
  }

  Future<void> dispose() async {
    await stopAll();

    await wakePhraseService.close();
    await commandService.close();
    await ttsService.dispose();
    await VoskModelManager.instance.dispose();

    await _stateController.close();
    await _statusController.close();
    await _partialController.close();
    await _finalController.close();
  }
}

