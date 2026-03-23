class AssistantService {
  Future<String> process(String input) async {
    final text = input.toLowerCase().trim();

    if (text.isEmpty) {
      return 'Non ho sentito nulla.';
    }

    if (text.contains('ciao')) {
      return 'Ciao, sono pronto.';
    }

    if (text.contains('come ti chiami')) {
      return 'Sono il tuo assistente vocale.';
    }

    if (text.contains('che ore sono')) {
      final now = DateTime.now();
      final mm = now.minute.toString().padLeft(2, '0');
      return 'Sono le ${now.hour} e $mm.';
    }

    if (text.contains('che giorno è')) {
      final now = DateTime.now();
      return 'Oggi è il giorno ${now.day}, mese ${now.month}, anno ${now.year}.';
    }

    //return 'Ho capito: $input';
    return input;
  }
}