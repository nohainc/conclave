part of '../projects_pages.dart';

class ProjectPage extends StatelessWidget {
  const ProjectPage({
    super.key,
    required this.project,
    required this.dataSource,
    required this.onOpenWorkstream,
    this.onOpenWorkspace,
    this.onEdit,
    required this.onArchive,
    required this.onDelete,
    this.onProjectUpdated,
  });

  final AxProject project;
  final AxDataSource dataSource;
  final ValueChanged<String> onOpenWorkstream;
  final ValueChanged<String>? onOpenWorkspace;
  final VoidCallback? onEdit;
  final VoidCallback onArchive;
  final VoidCallback onDelete;
  final ValueChanged<AxProject>? onProjectUpdated;

  @override
  Widget build(BuildContext context) => _ProjectWorkspace(
        key: ValueKey(project.id),
        project: project,
        dataSource: dataSource,
        onOpenWorkstream: onOpenWorkstream,
        onOpenWorkspace: onOpenWorkspace,
        onEdit: onEdit,
        onArchive: onArchive,
        onDelete: onDelete,
        onProjectUpdated: onProjectUpdated,
      );
}

class _ProjectWorkspace extends StatefulWidget {
  const _ProjectWorkspace({
    super.key,
    required this.project,
    required this.dataSource,
    required this.onOpenWorkstream,
    this.onOpenWorkspace,
    this.onEdit,
    required this.onArchive,
    required this.onDelete,
    this.onProjectUpdated,
  });

  final AxProject project;
  final AxDataSource dataSource;
  final ValueChanged<String> onOpenWorkstream;
  final ValueChanged<String>? onOpenWorkspace;
  final VoidCallback? onEdit;
  final VoidCallback onArchive;
  final VoidCallback onDelete;
  final ValueChanged<AxProject>? onProjectUpdated;

  @override
  State<_ProjectWorkspace> createState() => _ProjectWorkspaceState();
}

class _ProjectWorkspaceState extends State<_ProjectWorkspace>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  late List<AxWorkstream> workstreams;
  List<AxProjectMember> members = const [];
  List<AxProjectInvitation> invitations = const [];
  List<AxAuditEntry> audit = const [];
  List<AxWorkspace> ownedWorkspaces = const [];
  List<Map<String, dynamic>> projectWorkspaces = const [];
  bool loading = true;
  bool executionLoading = true;
  bool _savingField = false;
  String? _editingField;

  late TextEditingController _nameController;
  late TextEditingController _descriptionController;
  late TextEditingController _instructionsController;

  bool get canManage =>
      widget.project.role == 'owner' || widget.project.role == 'collaborator';
  bool get isOwner => widget.project.role == 'owner';

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _nameController = TextEditingController(text: widget.project.name);
    _descriptionController =
        TextEditingController(text: widget.project.description);
    _instructionsController =
        TextEditingController(text: widget.project.instructions);
    workstreams = [...widget.project.workstreams];
    _loadCollaboration();
    _loadExecution();
  }

  @override
  void didUpdateWidget(_ProjectWorkspace oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.project.id != widget.project.id ||
        oldWidget.project.name != widget.project.name ||
        oldWidget.project.description != widget.project.description ||
        oldWidget.project.instructions != widget.project.instructions) {
      if (_editingField == null) {
        _nameController.text = widget.project.name;
        _descriptionController.text = widget.project.description;
        _instructionsController.text = widget.project.instructions;
      }
    }
    if (oldWidget.project.id != widget.project.id ||
        oldWidget.project.workstreams != widget.project.workstreams) {
      workstreams = [...widget.project.workstreams];
      loading = true;
      executionLoading = true;
      _loadCollaboration();
      _loadExecution();
    }
  }

  @override
  void dispose() {
    _tabController.dispose();
    _nameController.dispose();
    _descriptionController.dispose();
    _instructionsController.dispose();
    super.dispose();
  }

  void _updateState(VoidCallback callback) => setState(callback);

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Project Data directly without group control card or horizontal lines
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Line 1: Project Name
                _buildEditableField(
                  label: 'Project Name',
                  fieldKey: 'name',
                  value: widget.project.name,
                  placeholder: 'Untitled Project',
                  controller: _nameController,
                  textStyle: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.3,
                  ),
                ),
                const SizedBox(height: 6),
                // Line 2: Description
                _buildEditableField(
                  label: 'Description',
                  fieldKey: 'description',
                  value: widget.project.description,
                  placeholder: 'No project description provided.',
                  controller: _descriptionController,
                  maxLines: 2,
                ),
                const SizedBox(height: 6),
                // Project instructions
                _buildEditableField(
                  label: 'Project Instructions',
                  fieldKey: 'instructions',
                  value: widget.project.instructions,
                  placeholder: 'No instructions configured.',
                  controller: _instructionsController,
                  maxLines: 3,
                ),
                if (isOwner) ...[
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 10,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      OutlinedButton.icon(
                        onPressed: widget.onArchive,
                        icon: const Icon(Icons.archive_outlined),
                        label: const Text('Archive'),
                      ),
                      TextButton.icon(
                        onPressed: widget.onDelete,
                        icon: const Icon(Icons.delete_outline),
                        label: const Text('Delete'),
                        style: TextButton.styleFrom(
                            foregroundColor: Colors.red.shade700),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),

          // 3 Tabs: Workstreams, Workspaces, Members aligned by center
          AnimatedBuilder(
            animation: _tabController,
            builder: (context, _) => Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: TabBar(
                    controller: _tabController,
                    isScrollable: true,
                    tabAlignment: TabAlignment.center,
                    tabs: const [
                      Tab(text: 'Workstreams'),
                      Tab(text: 'Workspaces'),
                      Tab(text: 'Members'),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                if (_tabController.index == 0)
                  _workstreamsTab()
                else if (_tabController.index == 1)
                  _workspacesTab()
                else
                  _membersTab(),
              ],
            ),
          ),
        ],
      );
}
