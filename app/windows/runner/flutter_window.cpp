#include "flutter_window.h"

#include <optional>
#include <shellapi.h>
#include <flutter/standard_method_codec.h>

#include "flutter/generated_plugin_registrant.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  file_drop_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "fh_radio_studio/file_drop",
      &flutter::StandardMethodCodec::GetInstance());
  DragAcceptFiles(GetHandle(), TRUE);
  audio_file_drop_ = new AudioFileDrop(GetHandle(), [this](const std::string& method, flutter::EncodableMap data) {
    if (file_drop_channel_) file_drop_channel_->InvokeMethod(method,
        std::make_unique<flutter::EncodableValue>(std::move(data)));
  });
  drop_parent_registered_ = SUCCEEDED(RegisterDragDrop(GetHandle(), audio_file_drop_));
  drop_child_registered_ = SUCCEEDED(RegisterDragDrop(flutter_controller_->view()->GetNativeWindow(), audio_file_drop_));
  audio_output_monitor_ = std::make_unique<AudioOutputMonitor>(
      flutter_controller_->engine()->messenger(), GetHandle());
  audio_output_monitor_->Start();
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (drop_child_registered_ && flutter_controller_) RevokeDragDrop(flutter_controller_->view()->GetNativeWindow());
  if (drop_parent_registered_) RevokeDragDrop(GetHandle());
  if (audio_file_drop_) { audio_file_drop_->Release(); audio_file_drop_ = nullptr; }
  DragAcceptFiles(GetHandle(), FALSE);
  file_drop_channel_ = nullptr;
  if (audio_output_monitor_) {
    audio_output_monitor_ = nullptr;
  }
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_DROPFILES: {
      // https://learn.microsoft.com/windows/win32/shell/wm-dropfiles
      const auto drop = reinterpret_cast<HDROP>(wparam);
      POINT point{};
      const bool client = DragQueryPoint(drop, &point) != FALSE;
      flutter::EncodableList paths;
      const UINT count = DragQueryFileW(drop, 0xFFFFFFFF, nullptr, 0);
      for (UINT index = 0; index < count; ++index) {
        const UINT length = DragQueryFileW(drop, index, nullptr, 0);
        std::wstring wide(length + 1, L'\0');
        DragQueryFileW(drop, index, wide.data(), length + 1);
        const int bytes = WideCharToMultiByte(CP_UTF8, 0, wide.data(), static_cast<int>(length), nullptr, 0, nullptr, nullptr);
        std::string path(bytes, '\0');
        WideCharToMultiByte(CP_UTF8, 0, wide.data(), static_cast<int>(length), path.data(), bytes, nullptr, nullptr);
        paths.emplace_back(path);
      }
      DragFinish(drop);
      if (client && file_drop_channel_) {
        const double scale = static_cast<double>(GetDpiForWindow(hwnd)) / 96.0;
        file_drop_channel_->InvokeMethod("filesDropped", std::make_unique<flutter::EncodableValue>(flutter::EncodableMap{
          {flutter::EncodableValue("paths"), flutter::EncodableValue(paths)},
          {flutter::EncodableValue("x"), flutter::EncodableValue(point.x / scale)},
          {flutter::EncodableValue("y"), flutter::EncodableValue(point.y / scale)},
        }));
      }
      return 0;
    }
    case kAudioOutputChangedMessage:
      if (audio_output_monitor_) {
        audio_output_monitor_->EmitDefaultOutputChanged();
      }
      return 0;
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
