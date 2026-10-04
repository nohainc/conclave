import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'controllers/profile_lab_controller.dart';
import 'theme/profile_lab_theme.dart';
import 'views/audit_view.dart';
import 'views/cloud_settings_dialog.dart';
import 'views/profiles_view.dart';
import 'views/releases_view.dart';
import 'views/tests_view.dart';
import 'views/workers_view.dart';
import 'views/workspaces_view.dart';

class ProfileLabApp extends StatefulWidget {
  const ProfileLabApp({super.key, required this.controller});

  final ProfileLabController controller;

  @override
  State<ProfileLabApp> createState() => _ProfileLabAppState();
}

class _ProfileLabAppState extends State<ProfileLabApp> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onStateChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        widget.controller.ensureTabData(widget.controller.selectedTab);
      }
    });
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onStateChanged);
    super.dispose();
  }

  void _onStateChanged() {
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;

    return MaterialApp(
      title: 'Conclave Profile Lab',
      debugShowCheckedModeBanner: false,
      theme: ProfileLabTheme.darkTheme,
      home: Scaffold(
        body: Column(
          children: [
            // Top branding & navigation header
            Container(
              height: 52,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              decoration: const BoxDecoration(
                color: ProfileLabTheme.darkSurface,
                border: Border(bottom: BorderSide(color: Color(0xFF334155))),
              ),
              child: Row(
                children: [
                  Image.asset(
                    'assets/branding/conclave_logo_32.png',
                    width: 24,
                    height: 24,
                    errorBuilder: (ctx, err, stack) => const Icon(Icons.science,
                        color: ProfileLabTheme.primaryAccent, size: 24),
                  ),
                  const SizedBox(width: 10),
                  const Text(
                    'CONCLAVE',
                    style: TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 13,
                        letterSpacing: 1.2),
                  ),
                  const SizedBox(width: 6),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color:
                          ProfileLabTheme.primaryAccent.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: const Text(
                      'PROFILE LAB',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.8,
                        color: ProfileLabTheme.primaryAccent,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),

                  // Navigation Tabs (Workers, Profiles, Tests, Releases, Workspaces, Audit)
                  Expanded(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          _NavTabButton(
                            label: 'Workers',
                            icon: Icons.engineering,
                            selected: c.selectedTab == LabTab.workers,
                            onTap: () => c.setTab(LabTab.workers),
                          ),
                          _NavTabButton(
                            label: 'Profiles',
                            icon: Icons.tune,
                            selected: c.selectedTab == LabTab.profiles,
                            onTap: () => c.setTab(LabTab.profiles),
                          ),
                          _NavTabButton(
                            label: 'Tests',
                            icon: Icons.fact_check_outlined,
                            selected: c.selectedTab == LabTab.tests,
                            onTap: () => c.setTab(LabTab.tests),
                          ),
                          _NavTabButton(
                            label: 'Releases',
                            icon: Icons.rocket_launch_outlined,
                            selected: c.selectedTab == LabTab.releases,
                            onTap: () => c.setTab(LabTab.releases),
                          ),
                          _NavTabButton(
                            label: 'Workspaces',
                            icon: Icons.devices,
                            selected: c.selectedTab == LabTab.workspaces,
                            onTap: () => c.setTab(LabTab.workspaces),
                          ),
                          _NavTabButton(
                            label: 'Audit',
                            icon: Icons.history_edu,
                            selected: c.selectedTab == LabTab.audit,
                            onTap: () => c.setTab(LabTab.audit),
                          ),
                        ],
                      ),
                    ),
                  ),

                  const SizedBox(width: 12),
                  IconButton(
                    icon: const Icon(Icons.cloud_outlined, size: 17),
                    tooltip: 'Cloud connection: ${c.cloudUrl}',
                    onPressed: () => CloudSettingsDialog.show(context, c),
                  ),
                  // Active Draft status chip
                  if (c.selectedDefinitionId != null) ...[
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: ProfileLabTheme.darkBackground,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: const Color(0xFF334155)),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.description,
                              size: 14, color: Color(0xFF94A3B8)),
                          const SizedBox(width: 6),
                          Text(
                            c.selectedDefinitionId!,
                            style: const TextStyle(
                                fontFamily: 'Menlo',
                                fontSize: 11,
                                fontWeight: FontWeight.w600),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                  ],

                  // Profile Lab Human Authentication Boundary
                  if (c.isSigningIn)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1E293B),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: ProfileLabTheme.warnColor),
                      ),
                      child: Row(
                        children: [
                          const SizedBox(
                            width: 12,
                            height: 12,
                            child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: ProfileLabTheme.warnColor),
                          ),
                          const SizedBox(width: 8),
                          const Text(
                            'Approve in browser...',
                            style: TextStyle(
                                fontSize: 11, color: ProfileLabTheme.warnColor),
                          ),
                          const SizedBox(width: 8),
                          InkWell(
                            onTap: c.cancelSignIn,
                            child: const Icon(Icons.close,
                                size: 14, color: Color(0xFF94A3B8)),
                          ),
                        ],
                      ),
                    )
                  else if (c.currentSession != null)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1E293B),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: const Color(0xFF334155)),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.person,
                              size: 14, color: ProfileLabTheme.primaryAccent),
                          const SizedBox(width: 6),
                          Text(
                            c.currentSession!.displayName,
                            style: const TextStyle(
                                fontSize: 11, fontWeight: FontWeight.w600),
                          ),
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 4, vertical: 1),
                            decoration: BoxDecoration(
                              color: ProfileLabTheme.primaryAccent
                                  .withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(3),
                            ),
                            child: const Text(
                              'profile-admin',
                              style: TextStyle(
                                  fontSize: 9,
                                  color: ProfileLabTheme.primaryAccent,
                                  fontWeight: FontWeight.bold),
                            ),
                          ),
                          const SizedBox(width: 6),
                          InkWell(
                            onTap: () => c.signOut(),
                            child: const Tooltip(
                              message: 'Sign Out',
                              child: Icon(Icons.logout,
                                  size: 14, color: Color(0xFF94A3B8)),
                            ),
                          ),
                        ],
                      ),
                    )
                  else
                    ElevatedButton.icon(
                      onPressed: () => c.signInWithBrowser(),
                      icon: const Icon(Icons.login, size: 13),
                      label: const Text('Sign In',
                          style: TextStyle(
                              fontSize: 11, fontWeight: FontWeight.w600)),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: ProfileLabTheme.primaryAccent,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 4),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                    ),
                ],
              ),
            ),

            if (c.authError != null && c.currentSession == null)
              _ProfileLabSignInError(
                message: 'Profile Lab sign-in failed: ${c.authError}',
              ),

            // Tab view content
            Expanded(
              child: switch (c.selectedTab) {
                LabTab.workers => WorkersView(controller: c),
                LabTab.profiles => ProfilesView(controller: c),
                LabTab.tests => TestsView(controller: c),
                LabTab.releases => ReleasesView(controller: c),
                LabTab.workspaces => WorkspacesView(controller: c),
                LabTab.audit => AuditView(controller: c),
              },
            ),

            // Bottom status bar
            Container(
              height: 28,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              decoration: const BoxDecoration(
                color: ProfileLabTheme.darkSurface,
                border: Border(top: BorderSide(color: Color(0xFF334155))),
              ),
              child: Row(
                children: [
                  const Text('Platform: macOS desktop (internal)',
                      style: TextStyle(fontSize: 11, color: Color(0xFF94A3B8))),
                  const SizedBox(width: 16),
                  Text(
                    'Engine: ${c.engineExecutable != null ? "Ready" : "Missing"}',
                    style: TextStyle(
                      fontSize: 11,
                      color: c.engineExecutable != null
                          ? ProfileLabTheme.passColor
                          : ProfileLabTheme.failColor,
                    ),
                  ),
                  const Spacer(),
                  if (c.currentDraft != null)
                    Text(
                      'Active Triplet: (${c.currentDraft!.profileDefinitionId}, v${c.currentDraft!.releaseVersion}, ${c.currentDraft!.payloadDigest.substring(0, 10)}...)',
                      style: const TextStyle(
                          fontFamily: 'Menlo',
                          fontSize: 10,
                          color: Color(0xFF94A3B8)),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProfileLabSignInError extends StatelessWidget {
  const _ProfileLabSignInError({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(16, 8, 12, 8),
        color: const Color(0xFF4A1F27),
        child: Row(
          children: [
            const Icon(Icons.error_outline, size: 18, color: Color(0xFFFF8A80)),
            const SizedBox(width: 8),
            Expanded(
              child: SelectableText(
                message,
                style: const TextStyle(color: Color(0xFFFFCDD2), fontSize: 12),
              ),
            ),
            IconButton(
              tooltip: 'Copy error message',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.copy, size: 18),
              color: const Color(0xFFFFCDD2),
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: message));
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Error message copied')),
                );
              },
            ),
          ],
        ),
      );
}

class _NavTabButton extends StatelessWidget {
  const _NavTabButton({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: selected
                ? ProfileLabTheme.primaryAccent.withValues(alpha: 0.15)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: selected
                  ? ProfileLabTheme.primaryAccent.withValues(alpha: 0.5)
                  : Colors.transparent,
            ),
          ),
          child: Row(
            children: [
              Icon(
                icon,
                size: 16,
                color: selected ? Colors.white : const Color(0xFF94A3B8),
              ),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                  color: selected ? Colors.white : const Color(0xFF94A3B8),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
