#include "win32_window.h"

#include <commctrl.h>
#include <dwmapi.h>
#include <windowsx.h>
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

  // Keep the standard overlapped capabilities so DWM can provide shadows,
  // rounded corners and normal snap/maximize behaviour. WM_NCCALCSIZE below
  // removes the visible native caption while preserving those capabilities.
  constexpr DWORD kFramelessStyle = WS_OVERLAPPEDWINDOW;
  window_handle_ = ::CreateWindow(
      window_class, title.c_str(), kFramelessStyle,
      Scale(static_cast<int>(origin.x), scale_factor),
      Scale(static_cast<int>(origin.y), scale_factor),
      Scale(static_cast<int>(size.width), scale_factor),
      Scale(static_cast<int>(size.height), scale_factor), nullptr, nullptr,
      ::GetModuleHandle(nullptr), this);
  if (window_handle_ == nullptr) {
    return false;
  }

  ::SetWindowPos(window_handle_, nullptr, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE |
                     SWP_FRAMECHANGED);

  // Windows 11 DWM: round the top-level window and suppress the native accent
  // border that can otherwise flash over Flutter's custom title bar.
  constexpr DWORD kCornerPreferenceAttribute = 33;
  constexpr DWORD kRoundPreference = 2;
  constexpr DWORD kBorderColorAttribute = 34;
  constexpr COLORREF kNoBorderColor = 0xFFFFFFFE;
  ::DwmSetWindowAttribute(
      window_handle_,
      static_cast<DWMWINDOWATTRIBUTE>(kCornerPreferenceAttribute),
      &kRoundPreference, sizeof(kRoundPreference));
  ::DwmSetWindowAttribute(
      window_handle_, static_cast<DWMWINDOWATTRIBUTE>(kBorderColorAttribute),
      &kNoBorderColor, sizeof(kNoBorderColor));
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
  if (child_content_ != nullptr && child_content_ != content) {
    ::RemoveWindowSubclass(child_content_, ChildContentSubclassProc, 1);
  }
  child_content_ = content;
  ::SetParent(content, window_handle_);
  // Flutter's engine view fills the complete client area. Without this
  // subclass, WM_NCHITTEST lands on the child HWND and the top-level window
  // never gets a chance to return HTLEFT/HTTOP/etc. Returning HTTRANSPARENT
  // only inside the resize border lets Windows continue hit testing the parent
  // while all normal client interactions still go straight to Flutter.
  ::SetWindowSubclass(content, ChildContentSubclassProc, 1,
                      reinterpret_cast<DWORD_PTR>(this));
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

LRESULT CALLBACK Win32Window::ChildContentSubclassProc(
    HWND window, UINT message, WPARAM wparam, LPARAM lparam,
    UINT_PTR subclass_id, DWORD_PTR reference_data) noexcept {
  auto* owner = reinterpret_cast<Win32Window*>(reference_data);
  if (message == WM_NCHITTEST && owner != nullptr &&
      owner->window_handle_ != nullptr) {
    const LRESULT hit = owner->HitTestResizeBorder(owner->window_handle_, lparam);
    if (hit != HTCLIENT) {
      return HTTRANSPARENT;
    }
  }
  if (message == WM_NCDESTROY) {
    ::RemoveWindowSubclass(window, ChildContentSubclassProc, subclass_id);
  }
  return ::DefSubclassProc(window, message, wparam, lparam);
}

LRESULT Win32Window::HitTestResizeBorder(HWND window,
                                         LPARAM lparam) const noexcept {
  if (::IsZoomed(window)) return HTCLIENT;
  RECT rect{};
  if (!::GetWindowRect(window, &rect)) return HTCLIENT;
  const int x = GET_X_LPARAM(lparam);
  const int y = GET_Y_LPARAM(lparam);
  const UINT dpi = ::GetDpiForWindow(window);
  const int border = ::MulDiv(8, dpi == 0 ? 96 : dpi, 96);
  const bool left = x >= rect.left && x < rect.left + border;
  const bool right = x <= rect.right && x > rect.right - border;
  const bool top = y >= rect.top && y < rect.top + border;
  const bool bottom = y <= rect.bottom && y > rect.bottom - border;
  if (top && left) return HTTOPLEFT;
  if (top && right) return HTTOPRIGHT;
  if (bottom && left) return HTBOTTOMLEFT;
  if (bottom && right) return HTBOTTOMRIGHT;
  if (left) return HTLEFT;
  if (right) return HTRIGHT;
  if (top) return HTTOP;
  if (bottom) return HTBOTTOM;
  return HTCLIENT;
}

LRESULT Win32Window::MessageHandler(HWND window, UINT message, WPARAM wparam,
                                    LPARAM lparam) noexcept {
  switch (message) {
    case WM_NCCALCSIZE:
      if (wparam == TRUE) {
        return 0;
      }
      return ::DefWindowProc(window, message, wparam, lparam);
    case WM_NCHITTEST:
      return HitTestResizeBorder(window, lparam);
    case WM_GETMINMAXINFO: {
      auto* info = reinterpret_cast<MINMAXINFO*>(lparam);
      const UINT dpi = ::GetDpiForWindow(window);
      const int effective_dpi = dpi == 0 ? 96 : static_cast<int>(dpi);
      info->ptMinTrackSize.x = ::MulDiv(720, effective_dpi, 96);
      info->ptMinTrackSize.y = ::MulDiv(520, effective_dpi, 96);

      // WS_POPUP frameless windows need explicit work-area bounds or a maximized
      // window may cover the taskbar. Match normal Windows window behavior.
      const HMONITOR monitor = ::MonitorFromWindow(window, MONITOR_DEFAULTTONEAREST);
      MONITORINFO monitor_info{};
      monitor_info.cbSize = sizeof(MONITORINFO);
      if (::GetMonitorInfo(monitor, &monitor_info)) {
        const RECT& work = monitor_info.rcWork;
        const RECT& full = monitor_info.rcMonitor;
        info->ptMaxPosition.x = work.left - full.left;
        info->ptMaxPosition.y = work.top - full.top;
        info->ptMaxSize.x = work.right - work.left;
        info->ptMaxSize.y = work.bottom - work.top;
      }
      return 0;
    }
    case WM_ERASEBKGND:
      // Flutter paints the complete client surface. Mark the erase as handled
      // to avoid a native gray/white flash during interactive resize.
      return 1;
    case WM_DESTROY:
      if (child_content_ != nullptr) {
        ::RemoveWindowSubclass(child_content_, ChildContentSubclassProc, 1);
      }
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
