abstract interface class PlatformServices {
  String get platformName;
}

final class DefaultPlatformServices implements PlatformServices {
  const DefaultPlatformServices();

  @override
  String get platformName => 'shared';
}

PlatformServices createPlatformServices() => const DefaultPlatformServices();
