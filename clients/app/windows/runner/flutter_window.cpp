#include "flutter_window.h"

#include <windows.h>

#include <optional>
#include <string>
#include <variant>

#include <flutter/standard_method_codec.h>

#include "desktop_notification.h"
#include "flutter/generated_plugin_registrant.h"

namespace {

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
        if (call.method_name() == "close") {
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
  flutter_controller_->engine()->SetNextFrameCallback([this]() { Show(); });
  flutter_controller_->ForceRedraw();
  return true;
}

void FlutterWindow::OnDestroy() {
  window_channel_.reset();
  flutter_controller_.reset();
  Win32Window::OnDestroy();
}

LRESULT FlutterWindow::MessageHandler(HWND hwnd, UINT message, WPARAM wparam,
                                      LPARAM lparam) noexcept {
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
