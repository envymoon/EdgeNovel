#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter_windows.h>
#include <windows.h>

#include <algorithm>

#include "flutter_window.h"
#include "utils.h"

// The app is laid out as one phone-width column, so the window opens that
// wide: about the width readers had been dragging it down to by hand.
static Win32Window::Size DefaultSize(const RECT& work, double scale) {
  const LONG work_height = static_cast<LONG>((work.bottom - work.top) / scale);
  return Win32Window::Size(
      600, static_cast<unsigned int>(std::clamp<LONG>(work_height, 480, 720)));
}

// Centres a window of |size| (logical pixels) in the primary work area.
static Win32Window::Point CentredOrigin(const RECT& work, double scale,
                                        const Win32Window::Size& size) {
  const LONG left = static_cast<LONG>(work.left / scale);
  const LONG top = static_cast<LONG>(work.top / scale);
  const LONG width = static_cast<LONG>((work.right - work.left) / scale);
  const LONG height = static_cast<LONG>((work.bottom - work.top) / scale);
  return Win32Window::Point(
      static_cast<unsigned int>(
          std::max<LONG>(0, left + (width - static_cast<LONG>(size.width)) / 2)),
      static_cast<unsigned int>(std::max<LONG>(
          0, top + (height - static_cast<LONG>(size.height)) / 2)));
}

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  RECT work = {0, 0, 1280, 720};
  ::SystemParametersInfo(SPI_GETWORKAREA, 0, &work, 0);
  const double scale =
      FlutterDesktopGetDpiForMonitor(::MonitorFromPoint(
          {work.left, work.top}, MONITOR_DEFAULTTOPRIMARY)) /
      96.0;
  Win32Window::Size size = DefaultSize(work, scale);
  Win32Window::Point origin = CentredOrigin(work, scale, size);
  if (!window.Create(L"novel", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
