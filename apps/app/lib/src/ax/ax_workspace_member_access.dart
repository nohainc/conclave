/// Workers, models and efforts a Workspace shares with invited Space members.
/// A null list shares every model or effort of that Worker.
class AxSharedWorker {
  const AxSharedWorker({this.models, this.efforts});
  final List<String>? models;
  final List<String>? efforts;
  factory AxSharedWorker.fromJson(Map<String, dynamic> json) => AxSharedWorker(
        models: (json['models'] as List?)?.whereType<String>().toList(),
        efforts: (json['efforts'] as List?)?.whereType<String>().toList(),
      );
  Map<String, dynamic> toJson() => {'models': models, 'efforts': efforts};
}

class AxWorkspaceMemberAccess {
  const AxWorkspaceMemberAccess(
      {this.restricted = false, this.workers = const {}});

  /// False means members may use whatever the owner's workflows select.
  final bool restricted;
  final Map<String, AxSharedWorker> workers;
  factory AxWorkspaceMemberAccess.fromJson(Map<String, dynamic> json) {
    final policy = json['policy'] as Map?;
    final workers = (policy?['workers'] as Map?) ?? const {};
    return AxWorkspaceMemberAccess(
      restricted: json['restricted'] == true,
      workers: {
        for (final entry in workers.entries)
          entry.key as String: AxSharedWorker.fromJson(
              Map<String, dynamic>.from(entry.value as Map)),
      },
    );
  }
  Map<String, dynamic> toJson() => {
        'restricted': restricted,
        if (restricted)
          'workers': {
            for (final entry in workers.entries)
              entry.key: entry.value.toJson(),
          },
      };
}

abstract interface class AxWorkspaceMemberAccessDataSource {
  Future<AxWorkspaceMemberAccess> loadWorkspaceMemberAccess(String workspaceId);
  Future<AxWorkspaceMemberAccess> saveWorkspaceMemberAccess(
      String workspaceId, AxWorkspaceMemberAccess access);
}
