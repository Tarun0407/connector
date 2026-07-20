#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <string>
#include <vector>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Single-instance check: create a named mutex
  HANDLE mutex = CreateMutexW(nullptr, FALSE, L"Global\\ConnectorAppSingleInstance");
  if (GetLastError() == ERROR_ALREADY_EXISTS) {
    // Another instance is running — send file paths and exit
    CloseHandle(mutex);

    HWND existing = FindWindowW(L"FLUTTER_RUNNER_WIN32_WINDOW", nullptr);
    if (existing) {
      // Collect file paths from command-line arguments
      int argc = 0;
      LPWSTR* argv = CommandLineToArgvW(GetCommandLineW(), &argc);
      if (argv) {
        std::wstring data;
        for (int i = 1; i < argc; i++) {
          std::wstring arg(argv[i]);
          if (GetFileAttributesW(arg.c_str()) != INVALID_FILE_ATTRIBUTES) {
            if (!data.empty()) data += L'\n';
            data += arg;
          }
        }
        LocalFree(argv);

        if (!data.empty()) {
          COPYDATASTRUCT cds;
          cds.dwData = 0;
          cds.cbData = static_cast<DWORD>((data.size() + 1) * sizeof(wchar_t));
          cds.lpData = const_cast<wchar_t*>(data.c_str());
          SendMessageW(existing, WM_COPYDATA, 0, reinterpret_cast<LPARAM>(&cds));
        }

        // Bring the existing window to foreground
        SetForegroundWindow(existing);
        ShowWindow(existing, SW_RESTORE);
      }
    }
    return EXIT_SUCCESS;
  }

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

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"connector", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(false);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  CloseHandle(mutex);
  ::CoUninitialize();
  return EXIT_SUCCESS;
}
