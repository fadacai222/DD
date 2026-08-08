#include "desktop_notification.h"

#include <gdiplus.h>
#include <windowsx.h>

#include <algorithm>
#include <memory>
#include <string>

namespace dd {
namespace {

constexpr wchar_t kNotificationClass[] = L"DDDesktopNotificationWindow";
constexpr UINT_PTR kDismissTimerId = 1;
constexpr UINT kDismissAfterMs = 5200;
HWND g_notification_window = nullptr;
ULONG_PTR g_gdiplus_token = 0;

struct NotificationState {
  HWND owner = nullptr;
  std::wstring title;
  std::wstring body;
  std::wstring avatar_path;
};

void EnsureGdiPlus() {
  if (g_gdiplus_token != 0) {
    return;
  }
  Gdiplus::GdiplusStartupInput input;
  if (Gdiplus::GdiplusStartup(&g_gdiplus_token, &input, nullptr) !=
      Gdiplus::Ok) {
    g_gdiplus_token = 0;
  }
}

void DrawAvatar(HDC dc, const RECT& bounds, const NotificationState& state) {
  const int size = bounds.bottom - bounds.top;
  EnsureGdiPlus();
  if (g_gdiplus_token != 0 && !state.avatar_path.empty()) {
    std::unique_ptr<Gdiplus::Image> image(
        Gdiplus::Image::FromFile(state.avatar_path.c_str(), FALSE));
    if (image && image->GetLastStatus() == Gdiplus::Ok) {
      Gdiplus::Graphics graphics(dc);
      graphics.SetInterpolationMode(Gdiplus::InterpolationModeHighQualityBicubic);
      graphics.SetSmoothingMode(Gdiplus::SmoothingModeAntiAlias);
      Gdiplus::GraphicsPath clip;
      clip.AddEllipse(bounds.left, bounds.top, size, size);
      graphics.SetClip(&clip);
      const UINT width = image->GetWidth();
      const UINT height = image->GetHeight();
      if (width > 0 && height > 0) {
        const double source_size = static_cast<double>(std::min(width, height));
        const double source_x = (static_cast<double>(width) - source_size) / 2.0;
        const double source_y = (static_cast<double>(height) - source_size) / 2.0;
        graphics.DrawImage(image.get(), Gdiplus::Rect(bounds.left, bounds.top, size, size),
                           static_cast<INT>(source_x), static_cast<INT>(source_y),
                           static_cast<INT>(source_size), static_cast<INT>(source_size),
                           Gdiplus::UnitPixel);
        graphics.ResetClip();
        return;
      }
    }
  }

  HBRUSH fallback = ::CreateSolidBrush(RGB(7, 193, 96));
  HBRUSH previous_brush = static_cast<HBRUSH>(::SelectObject(dc, fallback));
  HPEN null_pen = static_cast<HPEN>(::GetStockObject(NULL_PEN));
  HPEN previous_pen = static_cast<HPEN>(::SelectObject(dc, null_pen));
  ::Ellipse(dc, bounds.left, bounds.top, bounds.right, bounds.bottom);
  ::SelectObject(dc, previous_pen);
  ::SelectObject(dc, previous_brush);
  ::DeleteObject(fallback);

  const wchar_t initial = state.title.empty() ? L'?' : state.title.front();
  wchar_t text[2] = {initial, L'\0'};
  ::SetBkMode(dc, TRANSPARENT);
  ::SetTextColor(dc, RGB(255, 255, 255));
  HFONT font = ::CreateFontW(
      -24, 0, 0, 0, FW_SEMIBOLD, FALSE, FALSE, FALSE, DEFAULT_CHARSET,
      OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY,
      DEFAULT_PITCH | FF_DONTCARE, L"Segoe UI");
  HFONT old_font = static_cast<HFONT>(::SelectObject(dc, font));
  RECT text_bounds = bounds;
  ::DrawTextW(dc, text, -1, &text_bounds,
              DT_CENTER | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX);
  ::SelectObject(dc, old_font);
  ::DeleteObject(font);
}

void PaintNotification(HWND window, NotificationState* state) {
  PAINTSTRUCT paint{};
  HDC dc = ::BeginPaint(window, &paint);
  RECT client{};
  ::GetClientRect(window, &client);

  HBRUSH background = ::CreateSolidBrush(RGB(250, 250, 250));
  ::FillRect(dc, &client, background);
  ::DeleteObject(background);

  RECT avatar{14, 16, 70, 72};
  DrawAvatar(dc, avatar, *state);

  ::SetBkMode(dc, TRANSPARENT);
  ::SetTextColor(dc, RGB(30, 30, 30));
  HFONT title_font = ::CreateFontW(
      -16, 0, 0, 0, FW_SEMIBOLD, FALSE, FALSE, FALSE, DEFAULT_CHARSET,
      OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY,
      DEFAULT_PITCH | FF_DONTCARE, L"Segoe UI");
  HFONT body_font = ::CreateFontW(
      -14, 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE, DEFAULT_CHARSET,
      OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY,
      DEFAULT_PITCH | FF_DONTCARE, L"Segoe UI");

  RECT title_bounds{84, 14, client.right - 32, 37};
  HFONT old_font = static_cast<HFONT>(::SelectObject(dc, title_font));
  ::DrawTextW(dc, state->title.c_str(), -1, &title_bounds,
              DT_SINGLELINE | DT_END_ELLIPSIS | DT_NOPREFIX);

  ::SetTextColor(dc, RGB(92, 92, 92));
  RECT body_bounds{84, 39, client.right - 18, client.bottom - 10};
  ::SelectObject(dc, body_font);
  ::DrawTextW(dc, state->body.c_str(), -1, &body_bounds,
              DT_WORDBREAK | DT_END_ELLIPSIS | DT_NOPREFIX);

  ::SetTextColor(dc, RGB(150, 150, 150));
  RECT close_bounds{client.right - 28, 8, client.right - 8, 28};
  ::DrawTextW(dc, L"×", 1, &close_bounds,
              DT_CENTER | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX);

  ::SelectObject(dc, old_font);
  ::DeleteObject(title_font);
  ::DeleteObject(body_font);
  ::EndPaint(window, &paint);
}

LRESULT CALLBACK NotificationWindowProc(HWND window,
                                        UINT message,
                                        WPARAM wparam,
                                        LPARAM lparam) {
  auto* state = reinterpret_cast<NotificationState*>(
      ::GetWindowLongPtr(window, GWLP_USERDATA));
  switch (message) {
    case WM_NCCREATE: {
      const auto* create = reinterpret_cast<CREATESTRUCT*>(lparam);
      state = static_cast<NotificationState*>(create->lpCreateParams);
      ::SetWindowLongPtr(window, GWLP_USERDATA,
                         reinterpret_cast<LONG_PTR>(state));
      return TRUE;
    }
    case WM_ERASEBKGND:
      return 1;
    case WM_PAINT:
      if (state != nullptr) {
        PaintNotification(window, state);
        return 0;
      }
      break;
    case WM_LBUTTONUP:
      if (state != nullptr) {
        if (GET_X_LPARAM(lparam) >= 332 && GET_Y_LPARAM(lparam) <= 32) {
          ::DestroyWindow(window);
          return 0;
        }
        if (::IsIconic(state->owner)) {
          ::ShowWindow(state->owner, SW_RESTORE);
        } else {
          ::ShowWindow(state->owner, SW_SHOW);
        }
        ::SetForegroundWindow(state->owner);
      }
      ::DestroyWindow(window);
      return 0;
    case WM_TIMER:
      if (wparam == kDismissTimerId) {
        ::DestroyWindow(window);
        return 0;
      }
      break;
    case WM_NCDESTROY:
      ::KillTimer(window, kDismissTimerId);
      if (window == g_notification_window) {
        g_notification_window = nullptr;
      }
      delete state;
      ::SetWindowLongPtr(window, GWLP_USERDATA, 0);
      return 0;
  }
  return ::DefWindowProc(window, message, wparam, lparam);
}

bool EnsureWindowClass(HINSTANCE instance) {
  static bool registered = false;
  if (registered) {
    return true;
  }
  WNDCLASSW window_class{};
  window_class.lpfnWndProc = NotificationWindowProc;
  window_class.hInstance = instance;
  window_class.lpszClassName = kNotificationClass;
  window_class.hCursor = ::LoadCursor(nullptr, IDC_HAND);
  window_class.hbrBackground = nullptr;
  registered = ::RegisterClassW(&window_class) != 0 ||
               ::GetLastError() == ERROR_CLASS_ALREADY_EXISTS;
  return registered;
}

}  // namespace

bool ShowDesktopNotification(HWND owner,
                             const std::wstring& title,
                             const std::wstring& body,
                             const std::wstring& avatar_path) {
  HINSTANCE instance = ::GetModuleHandle(nullptr);
  if (owner == nullptr || instance == nullptr || !EnsureWindowClass(instance)) {
    return false;
  }
  if (g_notification_window != nullptr) {
    ::DestroyWindow(g_notification_window);
  }

  auto state = std::make_unique<NotificationState>();
  state->owner = owner;
  state->title = title.empty() ? L"DD" : title;
  state->body = body;
  state->avatar_path = avatar_path;

  constexpr int width = 360;
  constexpr int height = 92;
  RECT work_area{};
  if (!::SystemParametersInfoW(SPI_GETWORKAREA, 0, &work_area, 0)) {
    work_area.left = 0;
    work_area.top = 0;
    work_area.right = ::GetSystemMetrics(SM_CXSCREEN);
    work_area.bottom = ::GetSystemMetrics(SM_CYSCREEN);
  }
  const int x = work_area.right - width - 14;
  const int y = work_area.top + 14;

  HWND window = ::CreateWindowExW(
      WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE,
      kNotificationClass, L"DD notification", WS_POPUP,
      x, y, width, height, nullptr, nullptr, instance, state.release());
  if (window == nullptr) {
    return false;
  }
  g_notification_window = window;
  HRGN region = ::CreateRoundRectRgn(0, 0, width + 1, height + 1, 18, 18);
  if (region != nullptr) {
    ::SetWindowRgn(window, region, TRUE);
  }
  ::SetTimer(window, kDismissTimerId, kDismissAfterMs, nullptr);
  ::ShowWindow(window, SW_SHOWNOACTIVATE);
  ::UpdateWindow(window);
  return true;
}

}  // namespace dd
