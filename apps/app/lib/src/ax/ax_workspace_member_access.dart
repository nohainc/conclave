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

/// Ceiling on the work a person may run on a Workspace (ADR-020). A null mode
/// means no ceiling beyond Space role permissions.
const axWorkspaceAccessModes = ['chat', 'work', 'work+shell'];

class AxWorkspaceMemberAccess {
  const AxWorkspaceMemberAccess(
      {this.restricted = false, this.workers = const {}, this.mode});

  final String? mode;

  /// False means members may use whatever the owner's workflows select.
  final bool restricted;
  final Map<String, AxSharedWorker> workers;
  factory AxWorkspaceMemberAccess.fromJson(Map<String, dynamic> json) {
    final policy = json['policy'] as Map?;
    final workers = (policy?['workers'] as Map?) ?? const {};
    final mode = policy?['mode'];
    return AxWorkspaceMemberAccess(
      restricted: json['restricted'] == true,
      mode: axWorkspaceAccessModes.contains(mode) ? mode as String : null,
      workers: {
        for (final entry in workers.entries)
          entry.key as String: AxSharedWorker.fromJson(
              Map<String, dynamic>.from(entry.value as Map)),
      },
    );
  }
  Map<String, dynamic> toJson() => {
        'restricted': restricted,
        if (restricted && mode != null) 'mode': mode,
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

/// One person's effective access: [custom] is true when the owner replaced the
/// Workspace default for them.
class AxPersonAccess {
  const AxPersonAccess({required this.custom, required this.access});
  final bool custom;
  final AxWorkspaceMemberAccess access;
  factory AxPersonAccess.fromJson(Map<String, dynamic> json) => AxPersonAccess(
        custom: json['custom'] == true,
        // A person with no policy is unrestricted; reuse the workspace shape.
        access: AxWorkspaceMemberAccess.fromJson({
          'restricted': json['policy'] != null,
          'policy': json['policy'],
        }),
      );
}

abstract interface class AxWorkspacePersonAccessDataSource {
  Future<AxPersonAccess> loadPersonAccess(String workspaceId, String userId);
  Future<AxPersonAccess> savePersonAccess(
      String workspaceId, String userId, AxWorkspaceMemberAccess access);
  Future<AxPersonAccess> resetPersonAccess(String workspaceId, String userId);
}

/// Usage a lender sees for one borrower. Aggregate only; never content.
class AxPersonUsage {
  const AxPersonUsage(
      {this.requests = 0,
      this.approxSeconds = 0,
      this.lastUsedAt,
      this.workerIds = const []});
  final int requests;
  final int approxSeconds;
  final String? lastUsedAt;
  final List<String> workerIds;
  factory AxPersonUsage.fromJson(Map<String, dynamic> json) => AxPersonUsage(
        requests: (json['requests'] as num?)?.toInt() ?? 0,
        approxSeconds: (json['approxSeconds'] as num?)?.toInt() ?? 0,
        lastUsedAt: json['lastUsedAt'] as String?,
        workerIds: (json['workerIds'] as List?)?.whereType<String>().toList() ??
            const [],
      );
}

/// Someone holding a Person Grant on a Workspace (the lender's view).
class AxPersonWithAccess {
  const AxPersonWithAccess(
      {required this.userId,
      required this.displayName,
      required this.email,
      required this.status,
      this.custom = false,
      this.mode,
      this.maxConcurrentRequests = 1,
      this.usage = const AxPersonUsage()});
  final String userId;
  final String displayName;
  final String email;
  final String status;
  final bool custom;
  final String? mode;
  final int maxConcurrentRequests;
  final AxPersonUsage usage;
  bool get active => status == 'active';
  factory AxPersonWithAccess.fromJson(Map<String, dynamic> json) =>
      AxPersonWithAccess(
        userId: json['userId'] as String,
        displayName: json['displayName'] as String,
        email: json['email'] as String,
        status: json['status'] as String,
        custom: json['custom'] == true,
        mode: axWorkspaceAccessModes.contains(json['mode'])
            ? json['mode'] as String
            : null,
        maxConcurrentRequests:
            (json['maxConcurrentRequests'] as num?)?.toInt() ?? 1,
        usage: json['usage'] is Map
            ? AxPersonUsage.fromJson(
                Map<String, dynamic>.from(json['usage'] as Map))
            : const AxPersonUsage(),
      );
}

/// An invitation the Workspace owner sent.
class AxSharedWorkspaceInvitation {
  const AxSharedWorkspaceInvitation(
      {required this.id,
      required this.email,
      required this.status,
      required this.expiresAt});
  final String id;
  final String email;
  final String status;
  final String expiresAt;
  factory AxSharedWorkspaceInvitation.fromJson(Map<String, dynamic> json) =>
      AxSharedWorkspaceInvitation(
        id: json['id'] as String,
        email: json['email'] as String,
        status: json['status'] as String,
        expiresAt: json['expiresAt'] as String,
      );
}

/// An invitation addressed to the signed-in person.
class AxMyWorkspaceInvitation {
  const AxMyWorkspaceInvitation(
      {required this.id,
      required this.workspaceName,
      required this.ownerName,
      required this.expiresAt});
  final String id;
  final String workspaceName;
  final String ownerName;
  final String expiresAt;
  factory AxMyWorkspaceInvitation.fromJson(Map<String, dynamic> json) =>
      AxMyWorkspaceInvitation(
        id: json['id'] as String,
        workspaceName: json['workspaceName'] as String,
        ownerName: json['ownerName'] as String,
        expiresAt: json['expiresAt'] as String,
      );
}

/// Lending a Workspace to people (ADR-020): invitations, grants and quotas.
abstract interface class AxWorkspaceSharingDataSource {
  Future<List<AxPersonWithAccess>> loadPeopleWithAccess(String workspaceId);
  Future<List<AxSharedWorkspaceInvitation>> loadSharedWorkspaceInvitations(
      String workspaceId);
  Future<void> createWorkspaceInvitation(String workspaceId, String email);
  Future<void> revokeWorkspaceInvitation(
      String workspaceId, String invitationId);
  Future<void> revokePersonGrant(String workspaceId, String userId);
  Future<void> setPersonQuota(String workspaceId, String userId, int limit);
  Future<List<AxMyWorkspaceInvitation>> loadMyWorkspaceInvitations();
  Future<void> acceptWorkspaceInvitation(String invitationId);
}
