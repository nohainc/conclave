#include "flutter_window.h"

#include <optional>
#include <thread>
#include <flutter/standard_method_codec.h>
#include <winrt/base.h>
#include "windows_authentication.h"

namespace {
constexpr UINT kAuthenticationReply = WM_APP + 117;
struct AuthenticationReply {
  std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result;
  bool verified = false;
};
}


#include "flutter/generated_plugin_registrant.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  desktop_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "com.conclave.workspace/desktop",
      &flutter::StandardMethodCodec::GetInstance());
  desktop_channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    if (call.method_name() == "localManagementAuthAvailable") {
      result->Success(flutter::EncodableValue(true));
    } else if (call.method_name() == "authenticateLocalManagement") {
      const auto* reason = call.arguments() ? std::get_if<std::string>(call.arguments()) : nullptr;
      if (!reason) { result->Success(flutter::EncodableValue(false)); return; }
      auto reply = std::make_unique<AuthenticationReply>();
      reply->result = std::move(result);
      const auto owner = GetHandle();
      std::thread([owner, text = *reason, reply = std::move(reply)]() mutable {
        try {
          winrt::init_apartment(winrt::apartment_type::multi_threaded);
          reply->verified = AuthenticateCurrentWindowsUser(owner, text);
          winrt::uninit_apartment();
        } catch (...) { reply->verified = false; }
        auto* payload = reply.release();
        if (!PostMessage(owner, kAuthenticationReply, reinterpret_cast<WPARAM>(payload), 0)) delete payload;
      }).detach();
    } else { result->NotImplemented(); }
  });
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  MSG pending;
  while (PeekMessage(&pending, GetHandle(), kAuthenticationReply, kAuthenticationReply, PM_REMOVE)) {
    delete reinterpret_cast<AuthenticationReply*>(pending.wParam);
  }
  desktop_channel_.reset();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  if (message == kAuthenticationReply) {
    std::unique_ptr<AuthenticationReply> reply(reinterpret_cast<AuthenticationReply*>(wparam));
    reply->result->Success(flutter::EncodableValue(reply->verified));
    return 0;
  }
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
