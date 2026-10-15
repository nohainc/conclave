/// Calms the live status line of a Work request.
///
/// Before the provider starts, Cloud moves a request through several phases in
/// a few hundred milliseconds. Showing each one makes the line flicker without
/// telling the user anything. While [urgent] is false, this shows [neutral]
/// first and only switches to a different status once that status has been
/// stable for [settleDelay] and the status on screen has been visible for at
/// least [minDisplay]. A status that was replaced before settling is never
/// shown. An [urgent] update (the provider is running, new activity from the
/// Worker, a failure, a recovery notice) is shown immediately and resets the
/// state.
///
/// Pure and clock-free: the caller supplies `now`, so the rules are testable
/// without timers.
class AxStatusSettler {
  AxStatusSettler({
    this.neutral = defaultNeutral,
    this.settleDelay = const Duration(milliseconds: 700),
    this.minDisplay = const Duration(milliseconds: 600),
  });

  static const defaultNeutral = 'Starting…';

  /// Shown first while the real status is still changing.
  final String neutral;

  /// How long a status must stay unchanged before it replaces what is shown.
  final Duration settleDelay;

  /// How long the status on screen stays before it may be replaced.
  final Duration minDisplay;

  String? _displayed;
  DateTime? _displayedAt;
  String? _pending;
  DateTime? _pendingSince;

  /// The status currently on screen, or null when there is none.
  String? get displayed => _displayed;

  /// How long to wait before calling [update] again, set by the last call when
  /// a pending status is still settling. Null means nothing is pending.
  Duration? get nextCheck => _nextCheck;
  Duration? _nextCheck;

  /// Applies the latest [desired] status and returns the status to show.
  String? update(String? desired, DateTime now, {required bool urgent}) {
    _nextCheck = null;
    if (desired == null) {
      _reset();
      return null;
    }
    if (urgent) {
      _displayed = desired;
      _displayedAt = now;
      _pending = null;
      _pendingSince = null;
      return desired;
    }
    if (_displayed == null) {
      _displayed = neutral;
      _displayedAt = now;
    }
    if (desired == _displayed) {
      _pending = null;
      _pendingSince = null;
      return _displayed;
    }
    if (desired != _pending) {
      _pending = desired;
      _pendingSince = now;
    }
    final settledAt = _pendingSince!.add(settleDelay);
    final replaceableAt = _displayedAt!.add(minDisplay);
    final readyAt =
        settledAt.isAfter(replaceableAt) ? settledAt : replaceableAt;
    if (!now.isBefore(readyAt)) {
      _displayed = _pending;
      _displayedAt = now;
      _pending = null;
      _pendingSince = null;
      return _displayed;
    }
    _nextCheck = readyAt.difference(now);
    return _displayed;
  }

  void _reset() {
    _displayed = null;
    _displayedAt = null;
    _pending = null;
    _pendingSince = null;
  }
}
