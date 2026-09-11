extension StringExtension on String {
  bool isValidAPIKey() {
    final trimmed = trim();
    return RegExp(
      r'^(AIzaSy[A-Za-z0-9_-]{33}|AQ\.[A-Za-z0-9_\.-]{30,})$',
    ).hasMatch(trimmed);
  }
}
