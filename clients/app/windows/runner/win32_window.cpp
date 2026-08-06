#include "win32_window.h"

#include <dwmapi.h>
#include <flutter_windows.h>

namespace {

#ifndef DWMWA_USE_IMMERSIVE_DARK_MODE
#define DWMWA_USE_IMMERSIVE_DARK_MODE 20
#endif

constexpr wchar_t kWindowClassName[] = L"OPENIMX_FLUTTER_WINDOW";
constexpr wchar_t kThemeRegistryKey[] =
    L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize";
constexpr wchar_t kThemeRegistryValue[] = L"AppsUseLightTheme";

int active_window_count = 0;

int Scale(int value, double scale_factor) {
  return static_cast<int>(value * scale_factor);
}

}  // namespace

class WindowClassRegistrar {
 public:
  static WindowClassRegistrar* GetInstance() {
    static WindowClassRegistrar instance;
    return &instance;
  }

  const wchar_t* GetWindowClass() {
    if (!registered_) {
      WNDCLASS window_class{};
      window_class.hCursor = ::LoadCursor(nullptr, IDC_ARROW);
      window_class.lpszClassName = kWindowClassName;
      window_class.style = CS_HREDRAW | CS_VREDRAW;
      window_class.hInstance = ::GetModuleHandle(nullptr);
      window_class.hIcon = nullptr;
      window_class.hbrBackground = nullptr;
      window_class.lpfnWndProc = Win32Window::WndProc;
      if (::RegisterClass(&window_class) == 0) {
        return nullptr;
      }
      registered_ = true;
    }
    return kWindowClassName;
  }

  void UnregisterWindowClass() {
    if (!registered_) {
      return;
    }
    ::UnregisterClass(kWindowClassName, nullptr);
    registered_ = false;
  }

 private:
  bool registered_ = false;
};

Win32Window::Win32Window() {
  ++active_window_count;
}

Win32Window::~Win32Window() {
  Destroy();
  --active_window_count;
  if (active_window_count == 0) {
    WindowClassRegistrar::GetInstance()->UnregisterWindowClass();
  }
}

bool Win32Window::Create(const std::wstring& title, const Point& origin,
                         const Size& size) {
  Destroy();

  const wchar_t* window_class =
      WindowClassRegistrar::GetInstance()->GetWindowClass();
  if (window_class == nullptr) {
    return false;
  }

  const POINT target_point = {static_cast<LONG>(origin.x),
                              static_cast<LONG>(origin.y)};
  const HMONITOR monitor =
      ::MonitorFromPoint(target_point, MONITOR_DEFAULTTONEAREST);
  const UINT dpi = FlutterDesktopGetDpiForMonitor(monitor);
  const double scale_factor = static_cast<double>(dpi) / 96.0;

  window_handle_ = ::CreateWindow(
      window_class, title.c_str(), WS_OVERLAPPEDWINDOW,
      Scale(static_cast<int>(origin.x), scale_factor),
      Scale(static_cast<int>(origin.y), scale_factor),
      Scale(static_cast<int>(size.width), scale_factor),
      Scale(static_cast<int>(size.height), scale_factor), nullptr, nullptr,
      ::GetModuleHandle(nullptr), this);
  if (window_handle_ == nullptr) {
    return false;
  }

  UpdateTheme(window_handle_);
  return OnCreate();
}

bool Win32Window::Show() {
  return ::ShowWindow(window_handle_, SW_SHOWNORMAL) != 0;
}

void Win32Window::Destroy() {
  OnDestroy();
  if (window_handle_ != nullptr) {
    ::DestroyWindow(window_handle_);
    window_handle_ = nullptr;
  }
}

void Win32Window::SetChildContent(HWND content) {
  child_content_ = content;
  ::SetParent(content, window_handle_);
  const RECT frame = GetClientArea();
  ::MoveWindow(content, frame.left, frame.top, frame.right - frame.left,
               frame.bottom - frame.top, TRUE);
  ::SetFocus(child_content_);
}

HWND Win32Window::GetHandle() {
  return window_handle_;
}

void Win32Window::SetQuitOnClose(bool quit_on_close) {
  quit_on_close_ = quit_on_close;
}

RECT Win32Window::GetClientArea() {
  RECT frame{};
  ::GetClientRect(window_handle_, &frame);
  return frame;
}

LRESULT CALLBACK Win32Window::WndProc(HWND window, UINT message, WPARAM wparam,
                                      LPARAM lparam) noexcept {
  if (message == WM_NCCREATE) {
    const auto* create_struct = reinterpret_cast<CREATESTRUCT*>(lparam);
    auto* instance =
        static_cast<Win32Window*>(create_struct->lpCreateParams);
    ::SetWindowLongPtr(window, GWLP_USERDATA,
                       reinterpret_cast<LONG_PTR>(instance));
    instance->window_handle_ = window;
  } else if (Win32Window* instance = GetThisFromHandle(window)) {
    return instance->MessageHandler(window, message, wparam, lparam);
  }

  return ::DefWindowProc(window, message, wparam, lparam);
}

LRESULT Win32Window::MessageHandler(HWND window, UINT message, WPARAM wparam,
                                    LPARAM lparam) noexcept {
  switch (message) {
    case WM_DESTROY:
      window_handle_ = nullptr;
      child_content_ = nullptr;
      if (quit_on_close_) {
        ::PostQuitMessage(0);
      }
      return 0;
    case WM_DPICHANGED: {
      const auto* suggested = reinterpret_cast<RECT*>(lparam);
      ::SetWindowPos(window, nullptr, suggested->left, suggested->top,
                     suggested->right - suggested->left,
                     suggested->bottom - suggested->top,
                     SWP_NOZORDER | SWP_NOACTIVATE);
      return 0;
    }
    case WM_SIZE: {
      if (child_content_ != nullptr) {
        const RECT frame = GetClientArea();
        ::MoveWindow(child_content_, frame.left, frame.top,
                     frame.right - frame.left, frame.bottom - frame.top, TRUE);
      }
      return 0;
    }
    case WM_ACTIVATE:
      if (child_content_ != nullptr) {
        ::SetFocus(child_content_);
      }
      return 0;
    case WM_DWMCOLORIZATIONCOLORCHANGED:
      UpdateTheme(window);
      return 0;
    default:
      return ::DefWindowProc(window, message, wparam, lparam);
  }
}

bool Win32Window::OnCreate() {
  return true;
}

void Win32Window::OnDestroy() {}

Win32Window* Win32Window::GetThisFromHandle(HWND window) noexcept {
  return reinterpret_cast<Win32Window*>(
      ::GetWindowLongPtr(window, GWLP_USERDATA));
}

void Win32Window::UpdateTheme(HWND window) {
  DWORD use_light_theme = 1;
  DWORD value_size = sizeof(use_light_theme);
  const LSTATUS result = ::RegGetValue(
      HKEY_CURRENT_USER, kThemeRegistryKey, kThemeRegistryValue,
      RRF_RT_REG_DWORD, nullptr, &use_light_theme, &value_size);
  if (result != ERROR_SUCCESS) {
    return;
  }

  const BOOL enable_dark_mode = use_light_theme == 0;
  ::DwmSetWindowAttribute(window, DWMWA_USE_IMMERSIVE_DARK_MODE,
                          &enable_dark_mode, sizeof(enable_dark_mode));
}
