#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>

#include <memory>

#include "win32_window.h"

class FlutterWindow : public Win32Window {
 public:
  explicit FlutterWindow(const flutter::DartProject& project);
  ~FlutterWindow() override;

 protected:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT message, WPARAM wparam,
                         LPARAM lparam) noexcept override;

 private:
  bool AddTrayIcon(HWND window);
  void RemoveTrayIcon(HWND window);
  void HideToTray(HWND window);
  void RestoreFromTray(HWND window);
  void ShowTrayMenu(HWND window);

  flutter::DartProject project_;
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> window_channel_;
  UINT taskbar_created_message_ = 0;
  bool tray_icon_added_ = false;
  bool exit_requested_ = false;
  int tray_restore_command_ = SW_SHOWNORMAL;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
