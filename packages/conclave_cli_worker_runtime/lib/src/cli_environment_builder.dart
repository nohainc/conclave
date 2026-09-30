import 'dart:io';

class CliEnvironmentBuilder {
  const CliEnvironmentBuilder({this.allowedParentKeys = const {}});

  final Set<String> allowedParentKeys;

  Map<String, String> build({
    Map<String, String> values = const {},
    Map<String, String>? parentEnvironment,
  }) {
    final parent = parentEnvironment ?? Platform.environment;
    return {
      for (final key in allowedParentKeys)
        if (parent[key] case final value?) key: value,
      ...values,
    };
  }
}
