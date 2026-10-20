/// A short, best-effort device label; user-agent strings are untrusted metadata.
String accountSessionLabel(String? userAgent) {
  final agent = (userAgent ?? '')
      .replaceAll(
          RegExp(
              r'[\x00-\x1F\x7F\u200B-\u200F\u202A-\u202E\u2060-\u206F\uFEFF]'),
          '')
      .trim();
  if (agent.isEmpty) return 'Browser session';
  final browser = [
    ('Edg/', 'Edge'),
    ('EdgiOS/', 'Edge'),
    ('EdgA/', 'Edge'),
    ('OPR/', 'Opera'),
    ('SamsungBrowser/', 'Samsung Internet'),
    ('Firefox/', 'Firefox'),
    ('FxiOS/', 'Firefox'),
    ('Chrome/', 'Chrome'),
    ('CriOS/', 'Chrome'),
    ('Safari/', 'Safari'),
  ].where((entry) => agent.contains(entry.$1)).firstOrNull?.$2;
  final platform = [
    ('iPhone', 'iPhone'),
    ('iPad', 'iPad'),
    ('Android', 'Android'),
    ('Windows', 'Windows'),
    ('Macintosh', 'macOS'),
    ('Linux', 'Linux'),
  ].where((entry) => agent.contains(entry.$1)).firstOrNull?.$2;
  if (browser != null) {
    return platform == null ? browser : '$browser on $platform';
  }
  if (platform != null) return 'Browser on $platform';
  // Preserve short custom client names, but never render a raw UA paragraph.
  if (agent.length <= 48 && !agent.contains('Mozilla/')) return agent;
  return 'Browser session';
}
