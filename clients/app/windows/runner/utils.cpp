#include "utils.h"

#include <flutter_windows.h>
#include <io.h>
#include <shellapi.h>
#include <stdio.h>
#include <windows.h>

#include <iostream>

void CreateAndAttachConsole() {
  if (!::AllocConsole()) {
    return;
  }

  FILE* unused;
  if (freopen_s(&unused, "CONOUT$", "w", stdout) == 0) {
    _dup2(_fileno(stdout), 1);
  }
  if (freopen_s(&unused, "CONOUT$", "w", stderr) == 0) {
    _dup2(_fileno(stderr), 2);
  }
  std::ios::sync_with_stdio();
  FlutterDesktopResyncOutputStreams();
}

std::vector<std::string> GetCommandLineArguments() {
  int argument_count = 0;
  wchar_t** arguments =
      ::CommandLineToArgvW(::GetCommandLineW(), &argument_count);
  if (arguments == nullptr) {
    return {};
  }

  std::vector<std::string> result;
  for (int index = 1; index < argument_count; ++index) {
    result.push_back(Utf8FromUtf16(arguments[index]));
  }
  ::LocalFree(arguments);
  return result;
}

std::string Utf8FromUtf16(const wchar_t* utf16_string) {
  if (utf16_string == nullptr) {
    return {};
  }

  const int input_length = static_cast<int>(
      wcsnlen(utf16_string, UNICODE_STRING_MAX_CHARS));
  const int target_length = ::WideCharToMultiByte(
      CP_UTF8, WC_ERR_INVALID_CHARS, utf16_string, input_length, nullptr, 0,
      nullptr, nullptr);
  if (target_length <= 0) {
    return {};
  }

  std::string utf8_string(static_cast<size_t>(target_length), '\0');
  const int converted_length = ::WideCharToMultiByte(
      CP_UTF8, WC_ERR_INVALID_CHARS, utf16_string, input_length,
      utf8_string.data(), target_length, nullptr, nullptr);
  if (converted_length <= 0) {
    return {};
  }
  return utf8_string;
}
