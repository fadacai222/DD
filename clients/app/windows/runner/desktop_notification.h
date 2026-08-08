#ifndef RUNNER_DESKTOP_NOTIFICATION_H_
#define RUNNER_DESKTOP_NOTIFICATION_H_

#include <windows.h>

#include <string>

namespace dd {

// Shows a lightweight Telegram-style message popup without activating or
// stealing focus from the user's current application. A new notification
// replaces the previous popup; clicking it restores/focuses the DD window.
bool ShowDesktopNotification(HWND owner,
                             const std::wstring& title,
                             const std::wstring& body,
                             const std::wstring& avatar_path);

}  // namespace dd

#endif  // RUNNER_DESKTOP_NOTIFICATION_H_
