#ifndef RUNNER_WIN32_WINDOW_H_
#define RUNNER_WIN32_WINDOW_H_

#include <windows.h>

#include <string>

class Win32Window {
 public:
  struct Point {
    Point(unsigned int x_value, unsigned int y_value)
        : x(x_value), y(y_value) {}
    unsigned int x;
    unsigned int y;
  };

  struct Size {
    Size(unsigned int width_value, unsigned int height_value)
        : width(width_value), height(height_value) {}
    unsigned int width;
    unsigned int height;
  };

  Win32Window();
  virtual ~Win32Window();

  bool Create(const std::wstring& title, const Point& origin, const Size& size);
  bool Show();
  void Destroy();
  void SetChildContent(HWND content);
  HWND GetHandle();
  void SetQuitOnClose(bool quit_on_close);
  RECT GetClientArea();

 protected:
  virtual LRESULT MessageHandler(HWND window, UINT message, WPARAM wparam,
                                 LPARAM lparam) noexcept;
  virtual bool OnCreate();
  virtual void OnDestroy();

 private:
  friend class WindowClassRegistrar;

  static LRESULT CALLBACK WndProc(HWND window, UINT message, WPARAM wparam,
                                  LPARAM lparam) noexcept;
  static Win32Window* GetThisFromHandle(HWND window) noexcept;
  static void UpdateTheme(HWND window);

  bool quit_on_close_ = false;
  HWND window_handle_ = nullptr;
  HWND child_content_ = nullptr;
};

#endif  // RUNNER_WIN32_WINDOW_H_
