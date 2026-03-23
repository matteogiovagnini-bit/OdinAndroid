import 'package:vosk_flutter_service/vosk_flutter.dart';

class VoskModelManager {
  VoskModelManager._();

  static final VoskModelManager instance = VoskModelManager._();

  final VoskFlutterPlugin _vosk = VoskFlutterPlugin.instance();

  Model? _model;
  String? _modelPath;
  bool _loading = false;

  Future<Model> getModel() async {
    if (_model != null) {
      return _model!;
    }

    while (_loading) {
      await Future.delayed(const Duration(milliseconds: 50));
      if (_model != null) return _model!;
    }

    _loading = true;
    try {
      _modelPath ??= await ModelLoader().loadFromAssets(
        'assets/models/vosk-model-small-it-0.22.zip',
      );

      _model = await _vosk.createModel(_modelPath!);
      return _model!;
    } finally {
      _loading = false;
    }
  }

  Future<void> dispose() async {
    _model?.dispose();
    _model = null;
    _modelPath = null;
  }
}