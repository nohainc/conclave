import 'ax_thread_view_state_store_base.dart';
import 'ax_thread_view_state_store_stub.dart'
    if (dart.library.js_interop) 'ax_thread_view_state_store_web.dart'
    as platform;
export 'ax_thread_view_state_store_base.dart';

AxThreadViewStateStore createAxThreadViewStateStore() =>
    platform.createAxThreadViewStateStore();
