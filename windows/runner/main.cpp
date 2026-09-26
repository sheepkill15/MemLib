#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <algorithm>
#include <string>
#include <windows.h>

#include "app_links/app_links_plugin_c_api.h"

#include "flutter_window.h"
#include "utils.h"

namespace {

void RegisterAuthProtocol() {
  wchar_t executable[MAX_PATH] = {};
  const DWORD length = GetModuleFileNameW(nullptr, executable, MAX_PATH);
  if (length == 0 || length >= MAX_PATH) return;

  HKEY protocol = nullptr;
  if (RegCreateKeyExW(HKEY_CURRENT_USER,
                      L"Software\\Classes\\com.sheepkill15.memlib", 0, nullptr,
                      0, KEY_SET_VALUE | KEY_CREATE_SUB_KEY, nullptr, &protocol,
                      nullptr) != ERROR_SUCCESS) {
    return;
  }
  const wchar_t name[] = L"URL:Memlib authentication";
  const wchar_t empty[] = L"";
  RegSetValueExW(protocol, nullptr, 0, REG_SZ,
                 reinterpret_cast<const BYTE*>(name), sizeof(name));
  RegSetValueExW(protocol, L"URL Protocol", 0, REG_SZ,
                 reinterpret_cast<const BYTE*>(empty), sizeof(empty));

  HKEY command = nullptr;
  if (RegCreateKeyExW(protocol, L"shell\\open\\command", 0, nullptr, 0,
                      KEY_SET_VALUE, nullptr, &command, nullptr) == ERROR_SUCCESS) {
    const std::wstring value = L"\"" + std::wstring(executable) + L"\" \"%1\"";
    RegSetValueExW(command, nullptr, 0, REG_SZ,
                   reinterpret_cast<const BYTE*>(value.c_str()),
                   static_cast<DWORD>((value.size() + 1) * sizeof(wchar_t)));
    RegCloseKey(command);
  }
  RegCloseKey(protocol);
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  RegisterAuthProtocol();
  if (SendAppLinkToInstance()) return EXIT_SUCCESS;
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();
  const bool start_hidden =
      std::find(command_line_arguments.begin(), command_line_arguments.end(),
                "--background") != command_line_arguments.end();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project, start_hidden);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"memlib", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
