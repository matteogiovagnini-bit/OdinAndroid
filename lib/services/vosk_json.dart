import 'dart:convert';

String extractVoskPartial(String raw) {
  try {
    final map = jsonDecode(raw);
    if (map is Map<String, dynamic>) {
      return (map['partial'] as String? ?? '').trim();
    }
  } catch (_) {}
  return '';
}

String extractVoskText(String raw) {
  try {
    final map = jsonDecode(raw);
    if (map is Map<String, dynamic>) {
      return (map['text'] as String? ?? '').trim();
    }
  } catch (_) {}
  return '';
}