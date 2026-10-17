import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:timezone/data/latest_all.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

/// One usage window (for example "5 hours" or "Week") of a Worker's provider.
@immutable
class AxUsageWindow {
  const AxUsageWindow({
    required this.label,
    required this.usedPercent,
    this.group,
    this.resetsAt,
    this.resetsText,
  });

  final String label;

  /// Optional model group the window belongs to (Gemini reports several).
  final String? group;

  /// Percentage of the window already used, 0-100.
  final double usedPercent;

  /// Exact reset instant when the provider reports one.
  final DateTime? resetsAt;

  /// Reset time exactly as printed, for providers that omit a time zone
  /// offset or an absolute instant.
  final String? resetsText;

  double get remainingPercent => 100 - usedPercent;
}

/// Provider usage normalized into a common shape.
@immutable
class AxParsedUsage {
  const AxParsedUsage({required this.windows, this.notes = const []});

  final List<AxUsageWindow> windows;
  final List<String> notes;
}

/// Normalizes a provider CLI usage report. Returns null whenever the text does
/// not match a known format exactly, so callers show the original output
/// instead of a partial or guessed table.
///
/// The format is detected from the text, not from the Worker, because the
/// usage command is defined by the Worker's Tool Profile and may change.
AxParsedUsage? parseWorkerUsage(String output, {DateTime? now}) {
  final text = output.trim();
  if (text.isEmpty) return null;
  try {
    if (text.startsWith('{')) return _parseCodex(text);
    if (text.contains('Current session') || text.contains('Current week')) {
      return _parseClaude(text, now ?? DateTime.now());
    }
    return _parseGemini(text);
  } on Object {
    return null;
  }
}

bool _validPercent(num value) => value >= 0 && value <= 100;

AxParsedUsage? _parseClaude(String text, DateTime now) {
  final pattern = RegExp(
      r'^Current (session|week[^:]*):\s*(\d+(?:\.\d+)?)%\s*used'
      r'(?:\s*·\s*resets\s*(.+?))?\s*$',
      multiLine: true);
  final windows = <AxUsageWindow>[];
  for (final match in pattern.allMatches(text)) {
    final used = double.parse(match.group(2)!);
    if (!_validPercent(used)) return null;
    final kind = match.group(1)!;
    windows.add(AxUsageWindow(
      label: kind == 'session'
          ? 'Session'
          : kind.contains('all models')
              ? 'Week'
              : 'Week${kind.substring(4).trim().isEmpty ? '' : ' ${kind.substring(4).trim()}'}',
      usedPercent: used,
      resetsAt: _claudeReset(match.group(3), now),
      resetsText: match.group(3),
    ));
  }
  if (windows.isEmpty) return null;
  return AxParsedUsage(windows: windows);
}

String _minutesLabel(int minutes) {
  if (minutes == 10080) return 'Week';
  if (minutes % 1440 == 0) return '${minutes ~/ 1440} days';
  if (minutes % 60 == 0) {
    final hours = minutes ~/ 60;
    return hours == 1 ? '1 hour' : '$hours hours';
  }
  return '$minutes minutes';
}

AxParsedUsage? _parseCodex(String text) {
  final json = jsonDecode(text);
  if (json is! Map) return null;
  final limits = json['rateLimits'];
  if (limits is! Map) return null;
  final windows = <AxUsageWindow>[];
  for (final key in const ['primary', 'secondary']) {
    final entry = limits[key];
    if (entry == null) continue;
    if (entry is! Map) return null;
    final used = entry['usedPercent'];
    final minutes = entry['windowDurationMins'];
    final resets = entry['resetsAt'];
    if (used is! num || !_validPercent(used) || minutes is! int) return null;
    windows.add(AxUsageWindow(
      label: _minutesLabel(minutes),
      usedPercent: used.toDouble(),
      resetsAt: resets is int
          ? DateTime.fromMillisecondsSinceEpoch(resets * 1000, isUtc: true)
          : null,
    ));
  }
  if (windows.isEmpty) return null;
  final notes = <String>[];
  final credits = json['rateLimitResetCredits'];
  if (credits is Map && credits['availableCount'] is int) {
    final count = credits['availableCount'] as int;
    if (count > 0) {
      notes.add('$count free rate limit reset${count == 1 ? '' : 's'} '
          'available');
    }
  }
  if (json['ordinaryUsageAllowed'] == false) {
    notes.add('Ordinary usage is currently not allowed');
  }
  return AxParsedUsage(windows: windows, notes: notes);
}

AxParsedUsage? _parseGemini(String text) {
  final windows = <AxUsageWindow>[];
  for (final line in const LineSplitter().convert(text)) {
    if (line.trim().isEmpty) continue;
    final cells = line.split('\t').map((cell) => cell.trim()).toList();
    if (cells.length != 4) return null;
    final percent = RegExp(r'^(\d+(?:\.\d+)?)%$').firstMatch(cells[2]);
    final resets = DateTime.tryParse(cells[3]);
    if (percent == null || resets == null) return null;
    final remaining = double.parse(percent.group(1)!);
    if (!_validPercent(remaining)) return null;
    final detail = cells[1];
    final label = detail.contains('Five Hour')
        ? '5 hours'
        : detail.contains('Weekly')
            ? 'Week'
            : detail;
    windows.add(AxUsageWindow(
      group: cells[0],
      label: label,
      usedPercent: 100 - remaining,
      resetsAt: resets.toUtc(),
    ));
  }
  if (windows.isEmpty) return null;
  return AxParsedUsage(windows: windows);
}

bool _timeZonesInitialized = false;

// Claude omits the year. Resolve against the report's fetch time, in the
// explicitly reported IANA zone, rather than the browser's timezone.
DateTime? _claudeReset(String? text, DateTime now) {
  if (text == null) return null;
  final match = RegExp(
    r'^(?:([A-Z][a-z]{2}) (\d{1,2}) at )?(\d{1,2})(?::(\d{2}))?\s*(am|pm) \(([^)]+)\)$',
    caseSensitive: false,
  ).firstMatch(text);
  if (match == null) return null;
  try {
    if (!_timeZonesInitialized) {
      tz_data.initializeTimeZones();
      _timeZonesInitialized = true;
    }
    final location = tz.getLocation(match.group(6)!);
    final localNow = tz.TZDateTime.from(now, location);
    final hour = int.parse(match.group(3)!);
    final minute = int.parse(match.group(4) ?? '0');
    if (hour < 1 || hour > 12 || minute > 59) return null;
    final h = hour % 12 + (match.group(5)!.toLowerCase() == 'pm' ? 12 : 0);
    final monthName = match.group(1)?.toLowerCase();
    final month = monthName == null
        ? localNow.month
        : const [
              'jan',
              'feb',
              'mar',
              'apr',
              'may',
              'jun',
              'jul',
              'aug',
              'sep',
              'oct',
              'nov',
              'dec'
            ].indexOf(monthName) +
            1;
    final day = int.parse(match.group(2) ?? '${localNow.day}');
    if (month == 0 ||
        day < 1 ||
        day > DateTime.utc(localNow.year, month + 1, 0).day) {
      return null;
    }
    var reset = tz.TZDateTime(location, localNow.year, month, day, h, minute);
    if (reset.isBefore(localNow)) {
      reset = monthName == null
          ? tz.TZDateTime(location, localNow.year, month, day + 1, h, minute)
          : tz.TZDateTime(location, localNow.year + 1, month, day, h, minute);
    }
    return reset.toUtc();
  } on Object {
    return null;
  }
}

/// Minute-resolution countdown; expired reports never roll into a new window.
String usageResetLabel(AxUsageWindow window, DateTime now) {
  final at = window.resetsAt;
  if (at == null) {
    return window.resetsText == null ? '' : 'Resets ${window.resetsText}';
  }
  final remaining = at.difference(now);
  if (remaining <= Duration.zero) return 'Reset time reached — refresh usage';
  final minutes = (remaining.inMilliseconds / 60000).ceil();
  final weekly = window.label.startsWith('Week');
  final days = minutes ~/ 1440;
  final hours = weekly ? minutes % 1440 ~/ 60 : minutes ~/ 60;
  return 'Resets in ${weekly ? '$days d ' : ''}$hours hr ${minutes % 60} min';
}
