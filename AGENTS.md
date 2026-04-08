# AGENTS.md

## Project Overview
Odin Assistant - Android-first voice assistant with NFC gate authentication and ESP32 gimbal control.

## Entry Points
- `lib/main.dart` → `lib/app.dart` → `lib/ui/home_page.dart`
- Services: `lib/services/` (controller, TTS, Vosk, NFC, orientation)

## Developer Commands
```bash
flutter run                    # Run app
flutter analyze                # Lint + static analysis  
flutter test                   # Run tests
flutter build apk --debug      # Debug APK
flutter build apk --release    # Release APK
```

## Architecture Notes
- **Wake phrase**: "ehi odin" / "hey odin" (grammar in `wake_phrase_service.dart:32-36` - lowercase, matched case-insensitively)
- **NFC gate**: Device unlocks only with specific NFC tag (`kAllowedNfcTagId` in `home_page.dart:22`)
- **Gimbal**: ESP32 at `http://odin.local` (configurable via `kEsp32BaseUrl` in `home_page.dart:26`)
- **Vosk model**: Italian model bundled in `assets/models/vosk-model-small-it-0.22/`
- **TTS**: Native platform channel (`assistantapp/tts`) - no pub package

## Configuration Constants (home_page.dart)
- `kUseVisualAvatarUi` (default: true) - toggles between avatar UI and basic mode
- `kUseDiabolikStyle` (default: true) - alternate visual style
- `kGimbalTargetPitch` / `kGimbalTargetRoll` - initial gimbal pose targets

## Important Quirks
- Orientation calibration values are hardcoded in `orientation_service.dart:79-109` for specific phone mount position (landscape, display down)
- Gradle heap is set to 8GB in `android/gradle.properties`
- `test/widget_test.dart` references non-existent `MyApp` - update to `VoiceAssistantApp`
- `local_plugins/vosk_flutter/` is a separate fork/example; the app uses `vosk_flutter_service` from pub.dev

## Dependencies
- SDK: `>=3.3.0 <4.0.0`
- Key packages: `vosk_flutter_service`, `nfc_manager`, `permission_handler`, `sensors_plus`, `http`
