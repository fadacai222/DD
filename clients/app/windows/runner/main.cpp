#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE previous,
                      _In_ wchar_t* command_line, _In_ int show_command) {
  HANDLE single_instance_mutex =
      ::CreateMutexW(nullptr, FALSE, L"Local\\DDCommunityIM.SingleInstance");
  if (single_instance_mutex != nullptr &&
      ::GetLastError() == ERROR_ALREADY_EXISTS) {
    if (HWND existing = ::FindWindowW(nullptr, L"DD")) {
      if (!::IsWindowVisible(existing)) {
        ::ShowWindow(existing, SW_SHOW);
      } else if (::IsIconic(existing)) {
        ::ShowWindow(existing, SW_RESTORE);
      }
      ::SetForegroundWindow(existing);
      ::CloseHandle(single_instance_mutex);
      return EXIT_SUCCESS;
    }

    // A previous process can survive without a top-level window after an
    // interrupted Flutter/native startup. Do not let that stale mutex make
    // every later launch silently exit with no UI. Continue startup so DD can
    // recover and create a visible window.
  }

  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");
  // DD is a media-heavy desktop client. When Windows has both an integrated
  // and a discrete GPU, prefer the high-performance adapter instead of leaving
  // adapter selection to the system default.
  project.set_gpu_preference(
      flutter::GpuPreference::HighPerformancePreference);
  project.set_dart_entrypoint_arguments(GetCommandLineArguments());

  FlutterWindow window(project);
  const Win32Window::Point origin(80, 60);
  const Win32Window::Size size(881, 657);
  if (!window.Create(L"DD", origin, size)) {
    ::CoUninitialize();
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  MSG message;
  while (::GetMessage(&message, nullptr, 0, 0)) {
    ::TranslateMessage(&message);
    ::DispatchMessage(&message);
  }

  ::CoUninitialize();
  if (single_instance_mutex != nullptr) {
    ::CloseHandle(single_instance_mutex);
  }
  return EXIT_SUCCESS;
}
