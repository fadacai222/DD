#include "flutter_window.h"

#include <shellapi.h>
#include <windows.h>

#include <optional>
#include <string>
#include <variant>

#include <flutter/standard_method_codec.h>

#include "desktop_notification.h"
#include "flutter/generated_plugin_registrant.h"
#include "resource.h"

namespace {

constexpr UINT kTrayCallbackMessage = WM_APP + 73;
constexpr UINT kTrayIconId = 1;
constexpr UINT kTrayToggleCommand = 41001;
constexpr UINT kTrayExitCommand = 41002;

std::wstring WideFromUtf8(const std::string& value) {
  if (value.empty()) {
    return std::wstring();
  }
  const int required = ::MultiByteToWideChar(
      CP_UTF8, MB_ERR_INVALID_CHARS, value.data(), static_cast<int>(value.size()),
      nullptr, 0);
  if (required <= 0) {
    return std::wstring();
  }
  std::wstring result(required, L'\0');
  ::MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
                        static_cast<int>(value.size()), result.data(), required);
  return result;
}

std::string MapString(const flutter::EncodableMap& map, const char* key) {
  const auto iterator = map.find(flutter::EncodableValue(std::string(key)));
  if (iterator == map.end()) {
    return std::string();
  }
  const auto* value = std::get_if<std::string>(&iterator->second);
  return value == nullptr ? std::string() : *value;
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() = default;

bool FlutterWindow::AddTrayIcon(HWND window) {
  if (window == nullptr) {
    tray_icon_added_ = false;
    return false;
  }

  NOTIFYICONDATAW data{};
  data.cbSize = sizeof(data);
  data.hWnd = window;
  data.uID = kTrayIconId;
  data.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
  data.uCallbackMessage = kTrayCallbackMessage;
  data.hIcon = static_cast<HICON>(::LoadImageW(
      ::GetModuleHandleW(nullptr), MAKEINTRESOURCEW(IDI_APP_ICON),
      IMAGE_ICON, 0, 0, LR_DEFAULTSIZE | LR_SHARED));
  if (data.hIcon == nullptr) {
    data.hIcon = ::LoadIconW(nullptr, IDI_APPLICATION);
  }
  data.szTip[0] = L'D';
  data.szTip[1] = L'D';
  data.szTip[2] = L'\0';

  tray_icon_added_ = ::Shell_NotifyIconW(NIM_ADD, &data) != FALSE;
  return tray_icon_added_;
}

void FlutterWindow::RemoveTrayIcon(HWND window) {
  if (!tray_icon_added_ || window == nullptr) {
    return;
  }

  NOTIFYICONDATAW data{};
  data.cbSize = sizeof(data);
  data.hWnd = window;
  data.uID = kTrayIconId;
  ::Shell_NotifyIconW(NIM_DELETE, &data);
  tray_icon_added_ = false;
}

void FlutterWindow::HideToTray(HWND window) {
  if (!tray_icon_added_ && !AddTrayIcon(window)) {
    // Never make the app unreachable if Explorer rejected the tray icon.
    ::ShowWindow(window, SW_MINIMIZE);
    return;
  }

  if (::IsZoomed(window)) {
    tray_restore_command_ = SW_SHOWMAXIMIZED;
  } else if (::IsIconic(window)) {
    WINDOWPLACEMENT placement{};
    placement.length = sizeof(placement);
    tray_restore_command_ =
        ::GetWindowPlacement(window, &placement) &&
                (placement.flags & WPF_RESTORETOMAXIMIZED) != 0
            ? SW_SHOWMAXIMIZED
            : SW_SHOWNORMAL;
  } else {
    tray_restore_command_ = SW_SHOWNORMAL;
  }
  ::ShowWindow(window, SW_HIDE);
}

void FlutterWindow::RestoreFromTray(HWND window) {
  if (!::IsWindowVisible(window)) {
    ::ShowWindow(window, tray_restore_command_);
  } else if (::IsIconic(window)) {
    ::ShowWindow(window, SW_RESTORE);
  }
  ::SetForegroundWindow(window);
}

void FlutterWindow::ShowTrayMenu(HWND window) {
  const HMENU menu = ::CreatePopupMenu();
  if (menu == nullptr) {
    return;
  }

  const bool visible = ::IsWindowVisible(window) && !::IsIconic(window);
  ::AppendMenuW(menu, MF_STRING, kTrayToggleCommand,
                visible ? L"\u6700\u5c0f\u5316\u5230\u6258\u76d8"
                        : L"\u6253\u5f00 DD");
  ::AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  ::AppendMenuW(menu, MF_STRING, kTrayExitCommand, L"\u9000\u51fa DD");

  POINT cursor{};
  ::GetCursorPos(&cursor);
  ::SetForegroundWindow(window);
  const UINT command = ::TrackPopupMenu(
      menu, TPM_RETURNCMD | TPM_NONOTIFY | TPM_RIGHTBUTTON, cursor.x, cursor.y,
      0, window, nullptr);
  ::DestroyMenu(menu);
  ::PostMessageW(window, WM_NULL, 0, 0);

  if (command == kTrayToggleCommand) {
    if (visible) {
      HideToTray(window);
    } else {
      RestoreFromTray(window);
    }
    return;
  }
  if (command == kTrayExitCommand) {
    exit_requested_ = true;
    ::PostMessageW(window, WM_CLOSE, 0, 0);
  }
}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  const RECT frame = GetClientArea();
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }

  RegisterPlugins(flutter_controller_->engine());
  window_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "dd/window",
      &flutter::StandardMethodCodec::GetInstance());
  window_channel_->SetMethodCallHandler(
      [this](const auto& call, auto result) {
        const HWND window = GetHandle();
        if (window == nullptr) {
          result->Error("WINDOW_UNAVAILABLE", "Window handle is unavailable");
          return;
        }
        if (call.method_name() == "minimize") {
          ::ShowWindow(window, SW_MINIMIZE);
          result->Success();
          return;
        }
        if (call.method_name() == "toggleMaximize") {
          ::ShowWindow(window, ::IsZoomed(window) ? SW_RESTORE : SW_MAXIMIZE);
          result->Success(flutter::EncodableValue(::IsZoomed(window) != FALSE));
          return;
        }
        if (call.method_name() == "hideToTray") {
          HideToTray(window);
          result->Success();
          return;
        }
        if (call.method_name() == "close") {
          // Backward-compatible alias for older Dart builds. Close requests are
          // intentionally non-destructive and follow the same tray policy.
          ::PostMessage(window, WM_CLOSE, 0, 0);
          result->Success();
          return;
        }
        if (call.method_name() == "toggleAlwaysOnTop") {
          const LONG_PTR ex_style = ::GetWindowLongPtr(window, GWL_EXSTYLE);
          const bool currently_topmost = (ex_style & WS_EX_TOPMOST) != 0;
          ::SetWindowPos(window, currently_topmost ? HWND_NOTOPMOST : HWND_TOPMOST,
                         0, 0, 0, 0,
                         SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
          result->Success(flutter::EncodableValue(!currently_topmost));
          return;
        }
        if (call.method_name() == "startDrag") {
          // SendMessage enters Windows' modal move/size loop synchronously. When
          // called from Flutter's platform-channel handler that blocks the
          // platform thread until the drag ends, which presents as a frozen
          // title bar. Queue the non-client drag instead and return to Flutter
          // immediately.
          ::ReleaseCapture();
          POINT cursor{};
          ::GetCursorPos(&cursor);
          if (!::PostMessage(window, WM_NCLBUTTONDOWN, HTCAPTION,
                             MAKELPARAM(cursor.x, cursor.y))) {
            result->Error("WINDOW_DRAG_FAILED", "Unable to start window drag");
            return;
          }
          result->Success();
          return;
        }
        if (call.method_name() == "showNotification") {
          const auto* arguments =
              std::get_if<flutter::EncodableMap>(call.arguments());
          if (arguments == nullptr) {
            result->Error("INVALID_NOTIFICATION", "Notification payload is missing");
            return;
          }
          const bool shown = dd::ShowDesktopNotification(
              window, WideFromUtf8(MapString(*arguments, "title")),
              WideFromUtf8(MapString(*arguments, "body")),
              WideFromUtf8(MapString(*arguments, "avatarPath")));
          if (!shown) {
            result->Error("NOTIFICATION_FAILED", "Unable to create desktop notification");
            return;
          }
          result->Success();
          return;
        }
        if (call.method_name() == "isMaximized") {
          result->Success(flutter::EncodableValue(::IsZoomed(window) != FALSE));
          return;
        }
        result->NotImplemented();
      });
  SetChildContent(flutter_controller_->view()->GetNativeWindow());
  taskbar_created_message_ = ::RegisterWindowMessageW(L"TaskbarCreated");
  AddTrayIcon(GetHandle());
  flutter_controller_->engine()->SetNextFrameCallback([this]() { Show(); });
  flutter_controller_->ForceRedraw();
  return true;
}

void FlutterWindow::OnDestroy() {
  RemoveTrayIcon(GetHandle());
  window_channel_.reset();
  flutter_controller_.reset();
  Win32Window::OnDestroy();
}

LRESULT FlutterWindow::MessageHandler(HWND hwnd, UINT message, WPARAM wparam,
                                      LPARAM lparam) noexcept {
  if (taskbar_created_message_ != 0 && message == taskbar_created_message_) {
    // Explorer restarts remove notification icons. Re-register ours so a later
    // close request cannot strand the app with no way back in.
    tray_icon_added_ = false;
    AddTrayIcon(hwnd);
    return 0;
  }

  if (message == kTrayCallbackMessage) {
    if (lparam == WM_LBUTTONUP || lparam == WM_LBUTTONDBLCLK) {
      RestoreFromTray(hwnd);
    } else if (lparam == WM_RBUTTONUP || lparam == WM_CONTEXTMENU) {
      ShowTrayMenu(hwnd);
    }
    return 0;
  }

  if (message == WM_CLOSE) {
    if (!exit_requested_) {
      HideToTray(hwnd);
      return 0;
    }
    RemoveTrayIcon(hwnd);
    return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
  }

  if (message == WM_DESTROY) {
    RemoveTrayIcon(hwnd);
  }

  if (flutter_controller_) {
    const std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result.has_value()) {
      return result.value();
    }
  }

  if (message == WM_FONTCHANGE && flutter_controller_) {
    flutter_controller_->engine()->ReloadSystemFonts();
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
