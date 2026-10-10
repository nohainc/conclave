import 'dart:io';

import 'package:flutter/services.dart';

import 'workspace_background_service.dart';

/// Flutter adapter for the native macOS SMAppService bridge.
///
/// Other platforms deliberately use [UnsupportedWorkspaceServiceManager]
/// until their service host and credential/session models are implemented.
class MethodChannelWorkspaceServiceManager implements WorkspaceServiceManager {
  const MethodChannelWorkspaceServiceManager();

  static const _channel = MethodChannel('com.conclave.workspace/desktop');

  @override
  Future<WorkspaceBackgroundServiceStatus> status() async {
    if (!Platform.isMacOS) {
      return const UnsupportedWorkspaceServiceManager().status();
    }
    final value =
        await _channel.invokeMapMethod<Object?, Object?>('getServiceStatus');
    return WorkspaceBackgroundServiceStatus.fromNative(value ?? const {});
  }

  @override
  Future<WorkspaceBackgroundServiceStatus> register() async {
    if (!Platform.isMacOS) {
      throw UnsupportedError(
          'Background service management is currently supported only on macOS.');
    }
    final value =
        await _channel.invokeMapMethod<Object?, Object?>('registerService');
    return WorkspaceBackgroundServiceStatus.fromNative(value ?? const {});
  }

  @override
  Future<WorkspaceBackgroundServiceStatus> unregister() async {
    if (!Platform.isMacOS) {
      throw UnsupportedError(
          'Background service management is currently supported only on macOS.');
    }
    final value =
        await _channel.invokeMapMethod<Object?, Object?>('unregisterService');
    return WorkspaceBackgroundServiceStatus.fromNative(value ?? const {});
  }

  @override
  Future<void> openSettings() async {
    if (!Platform.isMacOS) {
      throw UnsupportedError(
          'Background service settings are currently supported only on macOS.');
    }
    await _channel.invokeMethod<void>('openLoginItemsSettings');
  }
}
