import 'package:conclave_profile_lab/profile_lab_cloud_config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ProfileLabCloudConfig', () {
    test('defaults to production Cloud', () {
      expect(
        ProfileLabCloudConfig.buildDefaultOrigin,
        profileLabProductionCloudOrigin,
      );
    });

    test('normalizes secure origins and development loopback', () {
      expect(
        ProfileLabCloudConfig.normalizeOrigin('https://Example.com/'),
        'https://example.com',
      );
      expect(
        ProfileLabCloudConfig.normalizeOrigin('http://localhost:8787'),
        'http://localhost:8787',
      );
      expect(
        ProfileLabCloudConfig.normalizeOrigin('http://127.0.0.1:8787'),
        'http://127.0.0.1:8787',
      );
    });

    test('rejects insecure remote hosts and non-origin URLs', () {
      expect(
        () => ProfileLabCloudConfig.normalizeOrigin('http://example.com'),
        throwsArgumentError,
      );
      expect(
        () => ProfileLabCloudConfig.normalizeOrigin(
          'http://localhost:8787',
          allowInsecureLoopback: false,
        ),
        throwsArgumentError,
      );
      expect(
        () => ProfileLabCloudConfig.normalizeOrigin('https://example.com/api'),
        throwsArgumentError,
      );
      expect(
        () => ProfileLabCloudConfig.normalizeOrigin(
          'https://user:password@example.com',
        ),
        throwsArgumentError,
      );
    });
  });
}
