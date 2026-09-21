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
    final lines = await file.readAsLines();
    for (var index = 0; index < lines.length; index++) {
      final line = lines[index];
      if (line.trim().isEmpty) continue;
      try {
        final record = AssignmentRecord.fromJson(
          Map<String, Object?>.from(jsonDecode(line) as Map),
        );
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
    return records;
  }
}
