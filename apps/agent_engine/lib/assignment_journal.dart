import 'dart:convert';
import 'dart:io';

enum AssignmentStatus { received, running, completed, failed, cancelled }

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

  factory AssignmentRecord.fromJson(Map<String, Object?> json) =>
      AssignmentRecord(
        assignmentId: json['assignmentId']! as String,
        status: AssignmentStatus.values.byName(json['status']! as String),
        updatedAt: DateTime.parse(json['updatedAt']! as String),
        result: json['result'] == null
            ? null
            : Map<String, Object?>.from(json['result']! as Map),
      );
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
        if (previous == null || record.updatedAt.isAfter(previous.updatedAt)) {
          records[record.assignmentId] = record;
        }
      } on Object {
        if (index != lines.length - 1) rethrow;
        // A crash may leave a partial final JSONL record. Earlier corruption
        // remains fatal so durable state is not silently discarded.
      }
    }
    return records;
  }
}
