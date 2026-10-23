import 'dart:io';

import 'package:flutter/services.dart';

import 'workspace_background_service.dart';
import 'linux_service_manager.dart';
import 'windows_service_manager.dart';

/// Flutter adapter for the native macOS SMAppService bridge.
///
/// Windows (logon task) and Linux (systemd user unit) delegate to their Dart
/// host adapters; other platforms use [UnsupportedWorkspaceServiceManager].
class MethodChannelWorkspaceServiceManager implements WorkspaceServiceManager {
  const MethodChannelWorkspaceServiceManager();

  static const _channel = MethodChannel('com.conclave.workspace/desktop');

  static WorkspaceServiceManager? get _hostManager {
    if (Platform.isWindows) return WindowsWorkspaceServiceManager();
    if (Platform.isLinux) return LinuxWorkspaceServiceManager();
    return null;
  }

  @override
  Future<WorkspaceServiceInfo> getInfo() async {
    final host = _hostManager;
    if (host != null) return host.getInfo();
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
    final host = _hostManager;
    if (host != null) return host.register();
    if (!Platform.isMacOS) {
      throw UnsupportedError(
          'Background service management is not supported on this platform.');
    }
    final value =
        await _channel.invokeMapMethod<Object?, Object?>('registerService');
    return WorkspaceServiceInfo.fromNative(value ?? const {});
  }

  @override
  Future<WorkspaceServiceInfo> unregister() async {
    final host = _hostManager;
    if (host != null) return host.unregister();
    if (!Platform.isMacOS) {
      throw UnsupportedError(
          'Background service management is not supported on this platform.');
    }
    final value =
        await _channel.invokeMapMethod<Object?, Object?>('unregisterService');
    return WorkspaceServiceInfo.fromNative(value ?? const {});
  }

  Future<WorkspaceServiceInfo> _invokeLifecycle(String method) async {
    final manager = _hostManager;
    if (manager != null) {
      return switch (method) {
        'startService' => manager.start(),
        'stopService' => manager.stop(),
        'restartService' => manager.restart(),
        _ => throw ArgumentError.value(method),
      };
    }
    if (!Platform.isMacOS) {
      throw UnsupportedError(
          'Background service management is not supported on this platform.');
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
    final host = _hostManager;
    if (host != null) return host.openSettings();
    if (!Platform.isMacOS) {
      throw UnsupportedError(
          'Background service settings are not supported on this platform.');
    }
    await _channel.invokeMethod<void>('openLoginItemsSettings');
  }
}
