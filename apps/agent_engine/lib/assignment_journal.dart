import 'dart:convert';
import 'dart:io';

enum AssignmentStatus {
  received,
  accepted,
  running,
  cancelling,
  completed,
  failed,
  cancelled,
  interrupted,
  resultPendingUpload,
  reconciled,
}

class AssignmentRecord {
  const AssignmentRecord({
    required this.assignmentId,
    required this.status,
    required this.updatedAt,
    this.result,
  });

  final String assignmentId;
  final AssignmentStatus status;
  final DateTime updatedAt;
  final Map<String, Object?>? result;

  Map<String, Object?> toJson() => {
        'assignmentId': assignmentId,
        'status': status.name,
        'updatedAt': updatedAt.toUtc().toIso8601String(),
        if (result != null) 'result': result,
      };

  factory AssignmentRecord.fromJson(Map<String, Object?> json) {
    final assignmentId = json['assignmentId'];
    final statusName = json['status'];
    final updatedAtText = json['updatedAt'];
    if (assignmentId is! String || assignmentId.isEmpty) {
      throw const FormatException('assignmentId is required');
    }
    if (statusName is! String || statusName.isEmpty) {
      throw const FormatException('status is required');
    }
    if (updatedAtText is! String || updatedAtText.isEmpty) {
      throw const FormatException('updatedAt is required');
    }
    final status = AssignmentStatus.values.asNameMap()[statusName];
    final updatedAt = DateTime.tryParse(updatedAtText);
    if (status == null) throw const FormatException('status is invalid');
    if (updatedAt == null) throw const FormatException('updatedAt is invalid');
    final rawResult = json['result'];
    if (rawResult != null && rawResult is! Map) {
      throw const FormatException('result must be an object');
    }
    return AssignmentRecord(
      assignmentId: assignmentId,
      status: status,
      updatedAt: updatedAt,
      result: rawResult == null
          ? null
          : Map<String, Object?>.from(rawResult as Map),
    );
  }
}

class AssignmentJournal {
  AssignmentJournal(this.file);
  final File file;

  Future<void> append(AssignmentRecord record) async {
    await file.parent.create(recursive: true);
    await file.writeAsString('${jsonEncode(record.toJson())}\n',
        mode: FileMode.append, flush: true);
  }

  Future<Map<String, AssignmentRecord>> reconcile() async {
    if (!await file.exists()) return {};
    final records = <String, AssignmentRecord>{};
    final history = <String, List<_JournalEntry>>{};
    final lines = await file.readAsLines();
    for (var index = 0; index < lines.length; index++) {
      final line = lines[index];
      if (line.trim().isEmpty) continue;
      try {
        final record = AssignmentRecord.fromJson(
          Map<String, Object?>.from(jsonDecode(line) as Map),
        );
        history
            .putIfAbsent(record.assignmentId, () => [])
            .add(_JournalEntry(index, record));
        final previous = records[record.assignmentId];
        if (previous == null ||
            record.updatedAt.isAfter(previous.updatedAt) ||
            record.updatedAt.isAtSameMomentAs(previous.updatedAt)) {
          records[record.assignmentId] = record;
        }
      } on Object {
        if (index != lines.length - 1 || line.trimRight().endsWith('}')) {
          rethrow;
        }
        // A crash may leave a partial final JSONL record. Earlier corruption
        // remains fatal so durable state is not silently discarded.
      }
    }
    for (final entries in history.values) {
      entries.sort((left, right) {
        final timestamp =
            left.record.updatedAt.compareTo(right.record.updatedAt);
        return timestamp == 0 ? left.index.compareTo(right.index) : timestamp;
      });
      for (var index = 1; index < entries.length; index++) {
        final previous = entries[index - 1].record.status;
        final next = entries[index].record.status;
        if (!_canTransition(previous, next)) {
          throw FormatException(
            'invalid assignment transition: ${previous.name} -> ${next.name}',
          );
        }
      }
    }
    return records;
  }
}

class _JournalEntry {
  const _JournalEntry(this.index, this.record);
  final int index;
  final AssignmentRecord record;
}

bool _canTransition(AssignmentStatus previous, AssignmentStatus next) {
  if (previous == next) return true;
  return switch (previous) {
    AssignmentStatus.received => {
        AssignmentStatus.accepted,
        AssignmentStatus.running,
        AssignmentStatus.cancelling,
        AssignmentStatus.cancelled,
        AssignmentStatus.interrupted,
      }.contains(next),
    AssignmentStatus.accepted => {
        AssignmentStatus.running,
        AssignmentStatus.cancelling,
        AssignmentStatus.cancelled,
        AssignmentStatus.interrupted,
      }.contains(next),
    AssignmentStatus.running => {
        AssignmentStatus.cancelling,
        AssignmentStatus.completed,
        AssignmentStatus.failed,
        AssignmentStatus.cancelled,
        AssignmentStatus.interrupted,
        AssignmentStatus.resultPendingUpload,
      }.contains(next),
    AssignmentStatus.cancelling => {
        AssignmentStatus.cancelled,
        AssignmentStatus.failed,
        AssignmentStatus.interrupted,
      }.contains(next),
    AssignmentStatus.interrupted => {
        AssignmentStatus.resultPendingUpload,
        AssignmentStatus.reconciled,
      }.contains(next),
    AssignmentStatus.resultPendingUpload => {
        AssignmentStatus.completed,
        AssignmentStatus.failed,
        AssignmentStatus.reconciled,
      }.contains(next),
    AssignmentStatus.completed ||
    AssignmentStatus.failed ||
    AssignmentStatus.cancelled =>
      next == AssignmentStatus.reconciled,
    AssignmentStatus.reconciled => false,
  };
}
