#include "windows_authentication.h"

#include <wincred.h>
#include <userconsentverifierinterop.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Security.Credentials.UI.h>
#include <vector>

namespace {
std::vector<BYTE> ReadTokenUser(HANDLE token) {
  DWORD size = 0;
  GetTokenInformation(token, ::TokenUser, nullptr, 0, &size);
  std::vector<BYTE> data(size);
  if (!size || !GetTokenInformation(token, ::TokenUser, data.data(), size, &size)) {
    return {};
  }
  return data;
}

bool VerifyPassword(HWND owner, const std::wstring& reason) {
  CREDUI_INFOW info{};
  info.cbSize = sizeof(info);
  info.hwndParent = owner;
  info.pszCaptionText = L"Conclave Workspace";
  info.pszMessageText = reason.c_str();
  ULONG package = 0, size = 0;
  LPVOID buffer = nullptr;
  if (CredUIPromptForWindowsCredentialsW(&info, 0, &package, nullptr, 0,
      &buffer, &size, nullptr, 0) != ERROR_SUCCESS) return false;
  wchar_t user[CREDUI_MAX_USERNAME_LENGTH + 1]{};
  wchar_t domain[CREDUI_MAX_DOMAIN_TARGET_LENGTH + 1]{};
  wchar_t password[CREDUI_MAX_PASSWORD_LENGTH + 1]{};
  DWORD user_size = ARRAYSIZE(user), domain_size = ARRAYSIZE(domain);
  DWORD password_size = ARRAYSIZE(password);
  HANDLE authenticated = nullptr, current = nullptr;
  bool verified = false;
  if (CredUnPackAuthenticationBufferW(0, buffer, size, user, &user_size,
      domain, &domain_size, password, &password_size) &&
      LogonUserW(user, domain[0] ? domain : nullptr, password,
        LOGON32_LOGON_INTERACTIVE, LOGON32_PROVIDER_DEFAULT, &authenticated) &&
      OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &current)) {
    auto expected = ReadTokenUser(current);
    auto actual = ReadTokenUser(authenticated);
    if (!expected.empty() && !actual.empty()) {
      verified = EqualSid(reinterpret_cast<TOKEN_USER*>(expected.data())->User.Sid,
          reinterpret_cast<TOKEN_USER*>(actual.data())->User.Sid) != FALSE;
    }
  }
  if (current) CloseHandle(current);
  if (authenticated) CloseHandle(authenticated);
  SecureZeroMemory(password, sizeof(password));
  SecureZeroMemory(user, sizeof(user));
  SecureZeroMemory(domain, sizeof(domain));
  SecureZeroMemory(buffer, size);
  CoTaskMemFree(buffer);
  return verified;
}
}  // namespace

bool AuthenticateCurrentWindowsUser(HWND owner, const std::string& reason) {
  const auto message = winrt::to_hstring(reason);
  try {
    using namespace winrt::Windows::Security::Credentials::UI;
    if (UserConsentVerifier::CheckAvailabilityAsync().get() ==
        UserConsentVerifierAvailability::Available) {
      auto interop = winrt::get_activation_factory<UserConsentVerifier,
          IUserConsentVerifierInterop>();
      winrt::Windows::Foundation::IAsyncOperation<UserConsentVerificationResult>
          operation{nullptr};
      winrt::check_hresult(interop->RequestVerificationForWindowAsync(owner,
          reinterpret_cast<HSTRING>(winrt::get_abi(message)), winrt::guid_of<decltype(operation)>(),
          winrt::put_abi(operation)));
      // Cancellation or a rejected verification is final, not another prompt.
      return operation.get() == UserConsentVerificationResult::Verified;
    }
  } catch (const winrt::hresult_error&) {
    // Older Windows builds may not expose the desktop Hello interop. Use the
    // OS credential dialog and verify the returned token belongs to this user.
  }
  return VerifyPassword(owner, std::wstring(message.c_str()));
}
