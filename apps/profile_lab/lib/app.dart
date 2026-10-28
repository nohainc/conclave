import 'package:syntila_design/syntila_design.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'controllers/profile_lab_controller.dart';
import 'profile_lab_cloud_config.dart';
import 'theme/profile_lab_theme.dart';
import 'widgets/lab_shortcuts.dart';
import 'widgets/lab_components.dart';
import 'views/workers_view.dart';

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
        widget.controller.ensureWorkerCatalog();
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
      title: 'Syntila Profile Lab',
      debugShowCheckedModeBanner: false,
      theme: ProfileLabTheme.darkTheme,
      builder: (context, child) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (ProfileLabCloudConfig.isLocalBuild)
            _LocalBuildBanner(origin: c.cloudUrl),
          Expanded(child: child ?? const SizedBox.shrink()),
        ],
      ),
      home: Builder(
          builder: (context) => Scaffold(
                  body: LabShortcuts(
                controller: c,
                child: Column(
                  children: [
                    // Top branding & navigation header
                    Container(
                      height: 52,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      decoration: const BoxDecoration(
                        color: ProfileLabTheme.darkSurface,
                        border: Border(
                            bottom:
                                BorderSide(color: ProfileLabTheme.borderColor)),
                      ),
                      child: Row(
                        children: [
                          SyntilaBrand.logoMark(size: 26),
                          const SizedBox(width: 12),
                          Text(
                            'Syntila Profile Lab',
                            style: SyntilaTypography.wordmark.copyWith(
                              fontSize: 14,
                              color: Colors.white,
                            ),
                          ),
                          const Spacer(),
                          // Profile Lab Human Authentication Boundary
                          if (c.isSigningIn)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 10, vertical: 4),
                              decoration: BoxDecoration(
                                color: ProfileLabTheme.darkSurface,
                                borderRadius: BorderRadius.circular(6),
                                border: Border.all(
                                    color: ProfileLabTheme.warnColor),
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
                                        fontSize: 11,
                                        color: ProfileLabTheme.warnColor),
                                  ),
                                  const SizedBox(width: 8),
                                  InkWell(
                                    onTap: c.cancelSignIn,
                                    child: const Icon(Icons.close,
                                        size: 14,
                                        color: ProfileLabTheme.secondaryText),
                                  ),
                                ],
                              ),
                            )
                          else if (c.currentSession != null)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 3),
                              decoration: BoxDecoration(
                                color: ProfileLabTheme.darkSurface,
                                borderRadius: BorderRadius.circular(6),
                                border: Border.all(
                                    color: ProfileLabTheme.borderColor),
                              ),
                              child: Row(
                                children: [
                                  const Icon(Icons.person,
                                      size: 14,
                                      color: ProfileLabTheme.primaryAccent),
                                  const SizedBox(width: 6),
                                  Text(
                                    c.currentSession!.displayName,
                                    style: const TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w600),
                                  ),
                                  const SizedBox(width: 6),
                                  Tooltip(
                                    message: c.labAccessError ??
                                        (c.labAccess == null
                                            ? 'Profile Lab permissions have not been verified.'
                                            : 'Profile administration: ${c.labAccess!.profilesAdmin ? "Authorized" : "Not authorized"}'),
                                    child: InkWell(
                                      onTap: c.isCheckingLabAccess
                                          ? null
                                          : () async {
                                              await c.refreshLabAccess();
                                              await c.ensureWorkerCatalog();
                                            },
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 6, vertical: 2),
                                        decoration: BoxDecoration(
                                          color: (c.labAccess?.profilesAdmin ==
                                                      true
                                                  ? ProfileLabTheme
                                                      .primaryAccent
                                                  : ProfileLabTheme.warnColor)
                                              .withValues(alpha: 0.15),
                                          borderRadius:
                                              BorderRadius.circular(4),
                                        ),
                                        child: Text(
                                          c.labAccess?.profilesAdmin == true
                                              ? 'Profile Admin'
                                              : 'Signed in',
                                          style: TextStyle(
                                              fontSize: 11,
                                              color: c.labAccess
                                                          ?.profilesAdmin ==
                                                      true
                                                  ? ProfileLabTheme
                                                      .primaryAccent
                                                  : ProfileLabTheme.warnColor,
                                              fontWeight: FontWeight.bold),
                                        ),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  InkWell(
                                    onTap: () => c.signOut(),
                                    child: const Tooltip(
                                      message: 'Sign Out',
                                      child: Icon(Icons.logout,
                                          size: 14,
                                          color: ProfileLabTheme.secondaryText),
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
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600)),
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
                    if (c.startupError != null)
                      _ProfileLabSignInError(
                        message:
                            'Profile Lab startup failed: ${c.startupError}',
                      ),
                    if (c.draftError != null)
                      _ProfileLabSignInError(
                        message: c.draftError!,
                      ),

                    // Main content
                    Expanded(
                      child: c.currentSession == null ||
                              c.labAccess == null ||
                              c.labAccess?.profilesAdmin == false ||
                              c.labAccessError != null
                          ? const EmptyState(
                              title: 'Profile Lab access is unavailable',
                              description:
                                  'Check access or sign in with the authorized owner account.')
                          : WorkersView(controller: c),
                    ),
                  ],
                ),
              ))),
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
        color: ProfileLabTheme.failColor.withValues(alpha: 0.2),
        child: Row(
          children: [
            const Icon(Icons.error_outline,
                size: 18, color: ProfileLabTheme.failColor),
            const SizedBox(width: 8),
            Expanded(
              child: SelectableText(
                message,
                style: const TextStyle(color: Colors.white, fontSize: 12),
              ),
            ),
            IconButton(
              tooltip: 'Copy error message',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.copy, size: 18),
              color: Colors.white,
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

/// Shown only in local development builds so they cannot be mistaken for the
/// production Profile Lab app.
class _LocalBuildBanner extends StatelessWidget {
  const _LocalBuildBanner({required this.origin});

  final String origin;

  @override
  Widget build(BuildContext context) => Material(
        color: SyntilaColors.warningTextLight,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 12),
          child: Text(
            'LOCAL DEVELOPMENT BUILD · Cloud API: $origin',
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.4,
            ),
          ),
        ),
      );
}
