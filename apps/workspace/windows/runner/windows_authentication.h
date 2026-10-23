#ifndef CONCLAVE_WINDOWS_AUTHENTICATION_H_
#define CONCLAVE_WINDOWS_AUTHENTICATION_H_
#include <windows.h>
#include <string>

// Native user-presence verification; never persists or returns OS credentials.
bool AuthenticateCurrentWindowsUser(HWND owner, const std::string& reason);
#endif
