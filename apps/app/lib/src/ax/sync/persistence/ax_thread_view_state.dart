import 'dart:convert';

/// Local-only state for reopening a Thread in the same place.
///
/// This object is deliberately separate from Cloud-backed Thread data. Draft
/// text is never included in a request until the user submits it.
class AxThreadViewState {
  const AxThreadViewState({
    this.tabIndex = 0,
    this.workflowReference,
    this.workerId,
    this.model,
    this.reasoningEffort,
    this.chatDraft = '',
    this.workDraft = '',
  });

  final int tabIndex;
  final String? workflowReference;
  final String? workerId;
  final String? model;
  final String? reasoningEffort;
  final String chatDraft;
  final String workDraft;

  Map<String, dynamic> toJson() => {
        'schemaVersion': 1,
        'tabIndex': tabIndex.clamp(0, 1),
        if (workflowReference != null) 'workflowReference': workflowReference,
        if (workerId != null) 'workerId': workerId,
        if (model != null) 'model': model,
        if (reasoningEffort != null) 'reasoningEffort': reasoningEffort,
        if (chatDraft.isNotEmpty) 'chatDraft': _bounded(chatDraft),
        if (workDraft.isNotEmpty) 'workDraft': _bounded(workDraft),
      };

  factory AxThreadViewState.fromJson(Map<String, dynamic> json) {
    String? string(String key) {
      final value = json[key];
      if (value is! String || value.isEmpty) return null;
      return value;
    }

    String draft(String key) {
      final value = json[key];
      return value is String ? _bounded(value) : '';
    }

    final tab = json['tabIndex'];
    return AxThreadViewState(
      tabIndex: tab is int ? tab.clamp(0, 1) : 0,
      workflowReference: string('workflowReference'),
      workerId: string('workerId'),
      model: string('model'),
      reasoningEffort: string('reasoningEffort'),
      chatDraft: draft('chatDraft'),
      workDraft: draft('workDraft'),
    );
  }

  static String _bounded(String value) =>
      value.length <= 200000 ? value : value.substring(value.length - 200000);

  String encode() => jsonEncode(toJson());
  static AxThreadViewState? decode(String value) {
    try {
      final decoded = jsonDecode(value);
      return decoded is Map
          ? AxThreadViewState.fromJson(Map<String, dynamic>.from(decoded))
          : null;
    } catch (_) {
      return null;
    }
  }
}
