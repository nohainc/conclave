import 'dart:io';

import 'package:flutter/services.dart';

import 'workspace_background_service.dart';
import 'windows_service_manager.dart';

/// Flutter adapter for the native macOS SMAppService bridge.
///
/// Other platforms deliberately use [UnsupportedWorkspaceServiceManager]
/// until their service host and credential/session models are implemented.
class MethodChannelWorkspaceServiceManager implements WorkspaceServiceManager {
  const MethodChannelWorkspaceServiceManager();

  static const _channel = MethodChannel('com.conclave.workspace/desktop');

  @override
  Future<WorkspaceServiceInfo> getInfo() async {
    if (Platform.isWindows) return WindowsWorkspaceServiceManager().getInfo();
    if (!Platform.isMacOS) {
      return const UnsupportedWorkspaceServiceManager().status();
    }
    final value =
        await _channel.invokeMapMethod<Object?, Object?>('getServiceInfo');
    return WorkspaceServiceInfo.fromNative(value ?? const {});
  }

  @override
  Future<WorkspaceServiceInfo> status() => getInfo();

  @override
  Future<WorkspaceServiceInfo> register() async {
    if (Platform.isWindows) return WindowsWorkspaceServiceManager().register();
    if (!Platform.isMacOS) {
      throw UnsupportedError(
          'Background service management is currently supported only on macOS.');
    }
    final value =
        await _channel.invokeMapMethod<Object?, Object?>('registerService');
    return WorkspaceServiceInfo.fromNative(value ?? const {});
  }

  @override
  Future<WorkspaceServiceInfo> unregister() async {
    if (Platform.isWindows)
      return WindowsWorkspaceServiceManager().unregister();
    if (!Platform.isMacOS) {
      throw UnsupportedError(
          'Background service management is currently supported only on macOS.');
    }
    final value =
        await _channel.invokeMapMethod<Object?, Object?>('unregisterService');
    return WorkspaceServiceInfo.fromNative(value ?? const {});
  }

  Future<WorkspaceServiceInfo> _invokeLifecycle(String method) async {
    if (Platform.isWindows) {
      final manager = WindowsWorkspaceServiceManager();
      return switch (method) {
        'startService' => manager.start(),
        'stopService' => manager.stop(),
        'restartService' => manager.restart(),
        _ => throw ArgumentError.value(method),
      };
    }
    if (!Platform.isMacOS) {
      throw UnsupportedError(
          'Background service management is currently supported only on macOS.');
    }
    final value = await _channel.invokeMapMethod<Object?, Object?>(method);
    return WorkspaceServiceInfo.fromNative(value ?? const {});
  }

  @override
  Future<WorkspaceServiceInfo> start() => _invokeLifecycle('startService');

  @override
  Future<WorkspaceServiceInfo> stop() => _invokeLifecycle('stopService');

  @override
  Future<WorkspaceServiceInfo> restart() => _invokeLifecycle('restartService');

  @override
  Future<void> openSettings() async {
    if (Platform.isWindows)
      return WindowsWorkspaceServiceManager().openSettings();
    if (!Platform.isMacOS) {
      throw UnsupportedError(
          'Background service settings are currently supported only on macOS.');
    }
    await _channel.invokeMethod<void>('openLoginItemsSettings');
  }
}
