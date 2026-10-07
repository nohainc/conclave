import 'package:conclave_design/conclave_design.dart';
import 'package:flutter/material.dart';

import '../theme/profile_lab_theme.dart';
import '../utils/provider_version_matrix.dart';

/// Card widget rendering the Provider Version Test Matrix.
/// Enforces strict visual separation between declared version bounds and physical test evidence.
class ProviderVersionMatrixCard extends StatelessWidget {
  const ProviderVersionMatrixCard({
    super.key,
    required this.profile,
    required this.evidenceList,
  });

  final Map<String, Object?> profile;
  final List<Map<String, Object?>> evidenceList;

  @override
  Widget build(BuildContext context) {
    final matrix = ProviderVersionMatrix.fromProfileAndEvidence(
      profile: profile,
      evidenceList: evidenceList,
    );

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                const Icon(Icons.grid_view_rounded,
                    size: 18, color: ProfileLabTheme.primaryAccent),
                const SizedBox(width: 8),
                const Text(
                  'Provider version test matrix',
                  style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 0.8,
                      color: Color(0xFF94A3B8)),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF59E0B).withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(
                        color: const Color(0xFFF59E0B).withValues(alpha: 0.4)),
                  ),
                  child: const Text(
                    'SUPPORTED ≠ TESTED',
                    style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFFFBBF24)),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),

            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Declared Support Range
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: ProfileLabTheme.darkSurface,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: const Color(0xFF334155)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Declared Version Support Range',
                          style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: Color(0xFF94A3B8)),
                        ),
                        const SizedBox(height: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: ProfileLabTheme.primaryAccent
                                .withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            matrix.declaredRangeSummary,
                            style: ConclaveTypography.mono.copyWith(
                              fontWeight: FontWeight.bold,
                              color: ProfileLabTheme.primaryAccent,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 12),

                // Physically Tested Versions
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: ProfileLabTheme.darkSurface,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: const Color(0xFF334155)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Physically Tested Locally',
                          style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: Color(0xFF94A3B8)),
                        ),
                        const SizedBox(height: 6),
                        if (matrix.hasTestedVersions)
                          Wrap(
                            spacing: 6,
                            runSpacing: 4,
                            children: matrix.testedEntries.map((entry) {
                              final isPass = entry.result == 'pass';
                              return Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 4),
                                decoration: BoxDecoration(
                                  color: (isPass
                                          ? ProfileLabTheme.passColor
                                          : ProfileLabTheme.failColor)
                                      .withValues(alpha: 0.15),
                                  borderRadius: BorderRadius.circular(4),
                                  border: Border.all(
                                    color: (isPass
                                            ? ProfileLabTheme.passColor
                                            : ProfileLabTheme.failColor)
                                        .withValues(alpha: 0.4),
                                  ),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      isPass
                                          ? Icons.check_circle
                                          : Icons.cancel,
                                      size: 12,
                                      color: isPass
                                          ? ProfileLabTheme.passColor
                                          : ProfileLabTheme.failColor,
                                    ),
                                    const SizedBox(width: 4),
                                    Text(
                                      entry.version,
                                      style: ConclaveTypography.monoSmall
                                          .copyWith(
                                        fontWeight: FontWeight.bold,
                                        color: isPass
                                            ? ProfileLabTheme.passColor
                                            : ProfileLabTheme.failColor,
                                      ),
                                    ),
                                  ],
                                ),
                              );
                            }).toList(),
                          )
                        else
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(
                              color: ProfileLabTheme.warnColor
                                  .withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: const Text(
                              'None tested locally',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                                color: ProfileLabTheme.warnColor,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),

            // Distinction Notice Banner
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: const Color(0xFF1E293B),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: const Color(0xFF334155)),
              ),
              child: Text(
                '${matrix.distinctionNotice} Physical test evidence guarantees runtime stability on evaluated provider versions.',
                style: const TextStyle(fontSize: 11, color: Color(0xFFCBD5E1)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
