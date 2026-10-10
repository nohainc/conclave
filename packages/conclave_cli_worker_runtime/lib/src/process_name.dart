import 'dart:ffi';
import 'dart:io';

/// Gives a native process a stable, product-facing name on macOS.
///
/// Dart's native runtime publishes AOT executables to Activity Monitor as
/// `dart:<executable>`.  The process itself is already the compiled native
/// executable; this LaunchServices name is only a macOS diagnostic/display
/// detail.  Keep the workaround isolated here so the service and Worker
/// Engine use the same naming behavior without adding a platform dependency to
/// the runtime protocol.
void setCurrentProcessName(String name) {
  if (!Platform.isMacOS || name.trim().isEmpty) return;

  try {
    final services = DynamicLibrary.open(
      '/System/Library/Frameworks/ApplicationServices.framework/Frameworks/'
      'HIServices.framework/HIServices',
    );
    final getCurrentProcess = services
        .lookupFunction<_GetCurrentProcessNative, _GetCurrentProcessDart>(
          'GetCurrentProcess',
        );
    final setProcessName = services
        .lookupFunction<_SetProcessNameNative, _SetProcessNameDart>(
          'CPSSetProcessName',
        );

    final system = DynamicLibrary.open('/usr/lib/libSystem.B.dylib');
    final malloc = system.lookupFunction<_MallocNative, _MallocDart>('malloc');
    final free = system.lookupFunction<_FreeNative, _FreeDart>('free');
    // ProcessSerialNumber is two 32-bit values. Keeping this as a plain
    // pointer avoids introducing a VM-only FFI Struct into callers that run
    // the shared package under Flutter's test compiler.
    final processSerialNumber = malloc(2 * sizeOf<Uint32>()).cast<Uint32>();
    final encodedName = malloc(name.length + 1);
    try {
      final bytes = encodedName.asTypedList(name.length + 1);
      for (var index = 0; index < name.length; index++) {
        bytes[index] = name.codeUnitAt(index);
      }
      bytes[name.length] = 0;

      if (getCurrentProcess(processSerialNumber) == 0) {
        setProcessName(processSerialNumber, encodedName);
      }
    } finally {
      free(encodedName);
      free(processSerialNumber.cast());
    }
  } on Object {
    // Process naming is best-effort diagnostics. It must never prevent the
    // service or an agent from starting on a future macOS/runtime variant.
  }
}

typedef _GetCurrentProcessNative = Int32 Function(Pointer<Uint32>);
typedef _GetCurrentProcessDart = int Function(Pointer<Uint32>);

typedef _SetProcessNameNative = Int32 Function(Pointer<Uint32>, Pointer<Uint8>);
typedef _SetProcessNameDart = int Function(Pointer<Uint32>, Pointer<Uint8>);

typedef _MallocNative = Pointer<Uint8> Function(IntPtr);
typedef _MallocDart = Pointer<Uint8> Function(int);
typedef _FreeNative = Void Function(Pointer<Uint8>);
typedef _FreeDart = void Function(Pointer<Uint8>);
