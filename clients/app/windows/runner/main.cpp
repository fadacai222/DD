#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE previous,
                      _In_ wchar_t* command_line, _In_ int show_command) {
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");
  project.set_dart_entrypoint_arguments(GetCommandLineArguments());

  FlutterWindow window(project);
  const Win32Window::Point origin(40, 40);
  const Win32Window::Size size(1280, 800);
  if (!window.Create(L"OpenIMX Realtime Console", origin, size)) {
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
  return EXIT_SUCCESS;
}
