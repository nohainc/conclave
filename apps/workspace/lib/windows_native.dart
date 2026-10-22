import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

/// Windows x64 platform seam. No native libraries are loaded on other hosts.
/// All temporary buffers are released; returned Win32 handles remain caller-owned.
class WindowsNative {
  WindowsNative._();
  static final _kernel = DynamicLibrary.open('kernel32.dll');
  static final _advapi = DynamicLibrary.open('advapi32.dll');
  static final _crypt = DynamicLibrary.open('crypt32.dll');
  static final _heap = _kernel
      .lookupFunction<IntPtr Function(), int Function()>('GetProcessHeap')();
  static final _alloc = _kernel.lookupFunction<
      Pointer<Void> Function(IntPtr, Uint32, IntPtr),
      Pointer<Void> Function(int, int, int)>('HeapAlloc');
  static final _free = _kernel.lookupFunction<
      Int32 Function(IntPtr, Uint32, Pointer<Void>),
      int Function(int, int, Pointer<Void>)>('HeapFree');
  static final _localFree = _kernel.lookupFunction<
      Pointer<Void> Function(Pointer<Void>),
      Pointer<Void> Function(Pointer<Void>)>('LocalFree');
  static final _error =
      _kernel.lookupFunction<Uint32 Function(), int Function()>('GetLastError');
  static final _currentProcess = _kernel
      .lookupFunction<IntPtr Function(), int Function()>('GetCurrentProcess');
  static final _close = _kernel
      .lookupFunction<Int32 Function(IntPtr), int Function(int)>('CloseHandle');

  static Pointer<Uint8> allocate(int bytes) {
    if (sizeOf<IntPtr>() != 8)
      throw UnsupportedError('Windows x64 is required');
    final p = _alloc(_heap, 8, bytes).cast<Uint8>();
    if (p == nullptr) throw StateError('Windows allocation failed');
    return p;
  }

  static void free(Pointer p) => _free(_heap, 0, p.cast<Void>());
  static Pointer<Uint16> wide(String text) {
    final p = allocate((text.length + 1) * 2).cast<Uint16>();
    p.asTypedList(text.length).setAll(0, text.codeUnits);
    return p;
  }

  static String _readWide(Pointer<Uint16> p) {
    var length = 0;
    while (length < 32768 && p[length] != 0) {
      length++;
    }
    return String.fromCharCodes(p.asTypedList(length));
  }

  static Never fail(String operation) => throw FileSystemException(
      '$operation failed (Windows error ${_error()})');
  static void close(int handle) {
    if (handle != 0 && handle != -1) _close(handle);
  }

  static String get currentSid {
    final token = allocate(8).cast<IntPtr>();
    final needed = allocate(4).cast<Uint32>();
    Pointer<Uint8>? data;
    try {
      final open = _advapi.lookupFunction<
          Int32 Function(IntPtr, Uint32, Pointer<IntPtr>),
          int Function(int, int, Pointer<IntPtr>)>('OpenProcessToken');
      if (open(_currentProcess(), 8, token) == 0) fail('OpenProcessToken');
      final info = _advapi.lookupFunction<
          Int32 Function(
              IntPtr, Uint32, Pointer<Void>, Uint32, Pointer<Uint32>),
          int Function(int, int, Pointer<Void>, int,
              Pointer<Uint32>)>('GetTokenInformation');
      info(token.value, 1, nullptr, 0, needed);
      data = allocate(needed.value);
      if (info(token.value, 1, data.cast(), needed.value, needed) == 0)
        fail('GetTokenInformation');
      return _sidString(data.cast<Pointer<Void>>().value);
    } finally {
      close(token.value);
      if (data != null) free(data);
      free(token);
      free(needed);
    }
  }

  static String _sidString(Pointer<Void> sid) {
    final result = allocate(8).cast<Pointer<Uint16>>();
    try {
      final convert = _advapi.lookupFunction<
          Int32 Function(Pointer<Void>, Pointer<Pointer<Uint16>>),
          int Function(Pointer<Void>,
              Pointer<Pointer<Uint16>>)>('ConvertSidToStringSidW');
      if (convert(sid, result) == 0) fail('ConvertSidToStringSidW');
      return _readWide(result.value);
    } finally {
      if (result.value != nullptr) _localFree(result.value.cast());
      free(result);
    }
  }

  static Pointer<Void> _descriptor({bool inherit = false}) {
    final sid = currentSid;
    final text = wide('O:${sid}D:P(A;${inherit ? 'OICI' : ''};GA;;;$sid)');
    final output = allocate(8).cast<Pointer<Void>>();
    try {
      final convert = _advapi.lookupFunction<
              Int32 Function(Pointer<Uint16>, Uint32, Pointer<Pointer<Void>>,
                  Pointer<Uint32>),
              int Function(Pointer<Uint16>, int, Pointer<Pointer<Void>>,
                  Pointer<Uint32>)>(
          'ConvertStringSecurityDescriptorToSecurityDescriptorW');
      if (convert(text, 1, output, nullptr) == 0)
        fail('Create private security descriptor');
      return output.value;
    } finally {
      free(text);
      free(output);
    }
  }

  static void securePath(String path) {
    final name = wide(File(path).absolute.path);
    final descriptor = _descriptor(inherit: true);
    try {
      final set = _advapi.lookupFunction<
          Int32 Function(Pointer<Uint16>, Uint32, Pointer<Void>),
          int Function(
              Pointer<Uint16>, int, Pointer<Void>)>('SetFileSecurityW');
      if (set(name, 0x80000004, descriptor) == 0)
        fail('Protect Workspace path');
    } finally {
      free(name);
      _localFree(descriptor);
    }
  }

  /// CurrentUser DPAPI with service/account entropy; no UI and no machine scope.
  static Uint8List protect(List<int> input, String context,
      {bool decrypt = false}) {
    final data = allocate(input.length);
    final entropyBytes = utf8.encode(context);
    final entropy = allocate(entropyBytes.length);
    final blob = allocate(16);
    final entropyBlob = allocate(16);
    final output = allocate(16);
    data.asTypedList(input.length).setAll(0, input);
    entropy.asTypedList(entropyBytes.length).setAll(0, entropyBytes);
    blob.cast<Uint32>().value = input.length;
    (blob + 8).cast<Pointer<Uint8>>().value = data;
    entropyBlob.cast<Uint32>().value = entropyBytes.length;
    (entropyBlob + 8).cast<Pointer<Uint8>>().value = entropy;
    try {
      final crypt = _crypt.lookupFunction<
              Int32 Function(Pointer<Void>, Pointer<Void>, Pointer<Void>,
                  Pointer<Void>, Pointer<Void>, Uint32, Pointer<Void>),
              int Function(Pointer<Void>, Pointer<Void>, Pointer<Void>,
                  Pointer<Void>, Pointer<Void>, int, Pointer<Void>)>(
          decrypt ? 'CryptUnprotectData' : 'CryptProtectData');
      if (crypt(blob.cast(), nullptr, entropyBlob.cast(), nullptr, nullptr, 1,
              output.cast()) ==
          0) fail('DPAPI');
      final length = output.cast<Uint32>().value;
      if (length > 1024 * 1024) throw StateError('Credential exceeds limit');
      return Uint8List.fromList(
          (output + 8).cast<Pointer<Uint8>>().value.asTypedList(length));
    } finally {
      final returned = (output + 8).cast<Pointer<Void>>().value;
      if (returned != nullptr) _localFree(returned);
      data.asTypedList(input.length).fillRange(0, input.length, 0);
      free(data);
      free(entropy);
      free(blob);
      free(entropyBlob);
      free(output);
    }
  }

  static int createPipe(String path, {required bool first}) {
    final name = wide(path);
    final descriptor = _descriptor();
    final attributes = allocate(24);
    attributes.cast<Uint32>().value = 24;
    (attributes + 8).cast<Pointer<Void>>().value = descriptor;
    try {
      final create = _kernel.lookupFunction<
          IntPtr Function(Pointer<Uint16>, Uint32, Uint32, Uint32, Uint32,
              Uint32, Uint32, Pointer<Void>),
          int Function(Pointer<Uint16>, int, int, int, int, int, int,
              Pointer<Void>)>('CreateNamedPipeW');
      // Byte mode; local clients only; protected DACL grants only the owner SID.
      final handle = create(name, 3 | (first ? 0x80000 : 0), 8, 32, 65536,
          65536, 5000, attributes.cast());
      if (handle == -1) fail('CreateNamedPipe');
      return handle;
    } finally {
      free(name);
      free(attributes);
      _localFree(descriptor);
    }
  }

  static bool acceptPipe(int handle) {
    final connect = _kernel.lookupFunction<
        Int32 Function(IntPtr, Pointer<Void>),
        int Function(int, Pointer<Void>)>('ConnectNamedPipe');
    return connect(handle, nullptr) != 0 || _error() == 535;
  }

  static int connectPipe(String path) {
    final name = wide(path);
    try {
      final open = _kernel.lookupFunction<
          IntPtr Function(Pointer<Uint16>, Uint32, Uint32, Pointer<Void>,
              Uint32, Uint32, IntPtr),
          int Function(Pointer<Uint16>, int, int, Pointer<Void>, int, int,
              int)>('CreateFileW');
      // Identification-only SQOS prevents a pipe server impersonating its client.
      final handle = open(name, 0xc0020000, 0, nullptr, 3, 0x110000, 0);
      if (handle == -1) fail('Open Workspace pipe');
      try {
        _verifyPipeOwner(handle);
      } catch (_) {
        close(handle);
        rethrow;
      }
      return handle;
    } finally {
      free(name);
    }
  }

  static void _verifyPipeOwner(int handle) {
    final owner = allocate(8).cast<Pointer<Void>>();
    final descriptor = allocate(8).cast<Pointer<Void>>();
    try {
      final get = _advapi.lookupFunction<
          Uint32 Function(
              IntPtr,
              Uint32,
              Uint32,
              Pointer<Pointer<Void>>,
              Pointer<Void>,
              Pointer<Void>,
              Pointer<Void>,
              Pointer<Pointer<Void>>),
          int Function(
              int,
              int,
              int,
              Pointer<Pointer<Void>>,
              Pointer<Void>,
              Pointer<Void>,
              Pointer<Void>,
              Pointer<Pointer<Void>>)>('GetSecurityInfo');
      if (get(handle, 6, 1, owner, nullptr, nullptr, nullptr, descriptor) !=
              0 ||
          _sidString(owner.value) != currentSid) {
        throw StateError('Workspace pipe is not owned by this user');
      }
    } finally {
      if (descriptor.value != nullptr) _localFree(descriptor.value);
      free(owner);
      free(descriptor);
    }
  }

  static Uint8List readPipe(int handle) {
    final buffer = allocate(65536);
    final count = allocate(4).cast<Uint32>();
    try {
      final read = _kernel.lookupFunction<
          Int32 Function(
              IntPtr, Pointer<Void>, Uint32, Pointer<Uint32>, Pointer<Void>),
          int Function(int, Pointer<Void>, int, Pointer<Uint32>,
              Pointer<Void>)>('ReadFile');
      if (read(handle, buffer.cast(), 65536, count, nullptr) == 0) {
        final code = _error();
        if ([6, 109, 232, 233, 995].contains(code)) return Uint8List(0);
        fail('Read Workspace pipe');
      }
      return Uint8List.fromList(buffer.asTypedList(count.value));
    } finally {
      free(buffer);
      free(count);
    }
  }

  static void writePipe(int handle, List<int> bytes) {
    final buffer = allocate(bytes.length);
    final count = allocate(4).cast<Uint32>();
    buffer.asTypedList(bytes.length).setAll(0, bytes);
    try {
      final write = _kernel.lookupFunction<
          Int32 Function(
              IntPtr, Pointer<Void>, Uint32, Pointer<Uint32>, Pointer<Void>),
          int Function(int, Pointer<Void>, int, Pointer<Uint32>,
              Pointer<Void>)>('WriteFile');
      var offset = 0;
      while (offset < bytes.length) {
        if (write(handle, (buffer + offset).cast(), bytes.length - offset,
                    count, nullptr) ==
                0 ||
            count.value == 0) fail('Write Workspace pipe');
        offset += count.value;
      }
    } finally {
      free(buffer);
      free(count);
    }
  }

  static void cancelPipe(int handle, {bool server = false}) {
    _kernel.lookupFunction<Int32 Function(IntPtr, Pointer<Void>),
        int Function(int, Pointer<Void>)>('CancelIoEx')(handle, nullptr);
    if (server)
      _kernel.lookupFunction<Int32 Function(IntPtr), int Function(int)>(
          'DisconnectNamedPipe')(handle);
  }
}
