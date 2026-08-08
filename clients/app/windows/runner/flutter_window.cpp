#include "flutter_window.h"

#include <optional>
#include <string>
#include <variant>

#include <flutter/standard_method_codec.h>

#include "flutter/generated_plugin_registrant.h"

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
          ::ReleaseCapture();
          ::SendMessage(window, WM_NCLBUTTONDOWN, HTCAPTION, 0);
          result->Success();
          return;
        }
        if (call.method_name() == "startResize") {
          const auto* edge = std::get_if<std::string>(call.arguments());
          if (edge == nullptr) {
            result->Error("INVALID_RESIZE_EDGE", "Resize edge is missing");
            return;
          }
          const int hit = *edge == "left"       ? HTLEFT
                          : *edge == "right"     ? HTRIGHT
                          : *edge == "top"       ? HTTOP
                          : *edge == "bottom"    ? HTBOTTOM
                          : *edge == "topLeft"   ? HTTOPLEFT
                          : *edge == "topRight"  ? HTTOPRIGHT
                          : *edge == "bottomLeft" ? HTBOTTOMLEFT
                          : *edge == "bottomRight" ? HTBOTTOMRIGHT
                                                   : HTNOWHERE;
          if (hit == HTNOWHERE) {
            result->Error("INVALID_RESIZE_EDGE", "Resize edge is invalid");
            return;
          }
          ::ReleaseCapture();
          ::SendMessage(window, WM_NCLBUTTONDOWN, hit, 0);
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
