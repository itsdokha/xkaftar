#include "flutter_window.h"

#include <chrono>
#include <condition_variable>
#include <deque>
#include <filesystem>
#include <future>
#include <functional>
#include <mutex>
#include <optional>
#include <string>
#include <thread>
#include <type_traits>
#include <utility>

#include <flutter/standard_method_codec.h>

#include <winrt/base.h>
#include <winrt/Windows.Devices.Enumeration.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Media.Capture.h>
#include <winrt/Windows.Media.MediaProperties.h>
#include <winrt/Windows.Storage.h>

#include "flutter/generated_plugin_registrant.h"

namespace {

namespace fs = std::filesystem;
using winrt::Windows::Devices::Enumeration::DeviceClass;
using winrt::Windows::Devices::Enumeration::DeviceInformation;
using winrt::Windows::Devices::Enumeration::Panel;
using winrt::Windows::Media::Capture::MediaCapture;
using winrt::Windows::Media::Capture::MediaCaptureInitializationSettings;
using winrt::Windows::Media::Capture::MediaCaptureSharingMode;
using winrt::Windows::Media::Capture::PhotoCaptureSource;
using winrt::Windows::Media::Capture::StreamingCaptureMode;
using winrt::Windows::Media::MediaProperties::MediaEncodingProfile;
using winrt::Windows::Media::MediaProperties::VideoEncodingQuality;
using winrt::Windows::Storage::CreationCollisionOption;
using winrt::Windows::Storage::StorageFile;
using winrt::Windows::Storage::StorageFolder;

std::mutex g_triangle_video_recorder_mutex;
MediaCapture g_triangle_video_capture{nullptr};
StorageFile g_triangle_video_file{nullptr};
bool g_triangle_video_recording = false;
std::mutex g_triangle_video_worker_mutex;
std::condition_variable g_triangle_video_worker_cv;
std::deque<std::function<void()>> g_triangle_video_worker_tasks;
std::thread g_triangle_video_worker;
bool g_triangle_video_worker_running = false;
bool g_triangle_video_worker_shutdown = false;

void EnsureTriangleRecorderWorker() {
  std::scoped_lock lock(g_triangle_video_worker_mutex);
  if (g_triangle_video_worker_running) {
    return;
  }

  g_triangle_video_worker_shutdown = false;
  g_triangle_video_worker = std::thread([]() {
    winrt::init_apartment(winrt::apartment_type::multi_threaded);
    std::unique_lock lock(g_triangle_video_worker_mutex);
    while (true) {
      g_triangle_video_worker_cv.wait(lock, []() {
        return g_triangle_video_worker_shutdown ||
               !g_triangle_video_worker_tasks.empty();
      });
      if (g_triangle_video_worker_shutdown &&
          g_triangle_video_worker_tasks.empty()) {
        break;
      }
      auto task = std::move(g_triangle_video_worker_tasks.front());
      g_triangle_video_worker_tasks.pop_front();
      lock.unlock();
      task();
      lock.lock();
    }
    winrt::uninit_apartment();
  });
  g_triangle_video_worker_running = true;
}

template <typename Func>
auto RunTriangleRecorderTask(Func&& func) -> decltype(func()) {
  using Result = decltype(func());

  EnsureTriangleRecorderWorker();

  auto promise = std::make_shared<std::promise<Result>>();
  auto future = promise->get_future();
  {
    std::scoped_lock lock(g_triangle_video_worker_mutex);
    g_triangle_video_worker_tasks.push_back(
        [promise, task = std::forward<Func>(func)]() mutable {
          try {
            if constexpr (std::is_void_v<Result>) {
              task();
              promise->set_value();
            } else {
              promise->set_value(task());
            }
          } catch (...) {
            promise->set_exception(std::current_exception());
          }
        });
  }
  g_triangle_video_worker_cv.notify_one();
  return future.get();
}

void ShutdownTriangleRecorderWorker() {
  std::thread worker;
  {
    std::scoped_lock lock(g_triangle_video_worker_mutex);
    if (!g_triangle_video_worker_running) {
      return;
    }
    g_triangle_video_worker_shutdown = true;
    worker = std::move(g_triangle_video_worker);
    g_triangle_video_worker_running = false;
  }
  g_triangle_video_worker_cv.notify_one();
  if (worker.joinable()) {
    worker.join();
  }
}

void CleanupTriangleRecorderState() {
  try {
    if (g_triangle_video_recording && g_triangle_video_capture) {
      g_triangle_video_capture.StopRecordAsync().get();
    }
  } catch (...) {
  }
  try {
    if (g_triangle_video_capture) {
      g_triangle_video_capture.Close();
    }
  } catch (...) {
  }
  g_triangle_video_capture = nullptr;
  g_triangle_video_file = nullptr;
  g_triangle_video_recording = false;
}

std::optional<DeviceInformation> SelectTriangleCamera(std::string* error_message) {
  auto devices = DeviceInformation::FindAllAsync(DeviceClass::VideoCapture).get();
  if (devices.Size() == 0) {
    if (error_message != nullptr) {
      *error_message = "No camera was found on this Windows device.";
    }
    return std::nullopt;
  }

  DeviceInformation selected = devices.GetAt(0);
  for (uint32_t index = 0; index < devices.Size(); ++index) {
    auto device = devices.GetAt(index);
    auto enclosure = device.EnclosureLocation();
    if (enclosure && enclosure.Panel() == Panel::Front) {
      selected = device;
      break;
    }
  }

  return selected;
}

std::optional<std::string> StartTriangleVideoRecording(std::string* error_message) {
  return RunTriangleRecorderTask([error_message]() -> std::optional<std::string> {
    std::scoped_lock lock(g_triangle_video_recorder_mutex);

    if (g_triangle_video_recording) {
      if (error_message != nullptr) {
        *error_message = "Triangle video recording is already running.";
      }
      return std::nullopt;
    }

    auto selected_camera = SelectTriangleCamera(error_message);
    if (!selected_camera.has_value()) {
      return std::nullopt;
    }

    try {
      const auto temp_directory = fs::temp_directory_path() / "kaftar-triangle-videos";
      fs::create_directories(temp_directory);

      const auto timestamp_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
                                    std::chrono::system_clock::now().time_since_epoch())
                                    .count();
      const auto file_name = L"triangle-" + std::to_wstring(timestamp_ms) + L".mp4";

      auto settings = MediaCaptureInitializationSettings();
      settings.VideoDeviceId(selected_camera->Id());
      settings.StreamingCaptureMode(StreamingCaptureMode::AudioAndVideo);
      settings.PhotoCaptureSource(PhotoCaptureSource::VideoPreview);
      settings.SharingMode(MediaCaptureSharingMode::ExclusiveControl);

      g_triangle_video_capture = MediaCapture();
      g_triangle_video_capture.InitializeAsync(settings).get();

      auto folder = StorageFolder::GetFolderFromPathAsync(
          winrt::hstring(temp_directory.wstring())).get();
      g_triangle_video_file = folder.CreateFileAsync(
          winrt::hstring(file_name),
          CreationCollisionOption::GenerateUniqueName).get();

      auto profile = MediaEncodingProfile::CreateMp4(VideoEncodingQuality::HD720p);
      g_triangle_video_capture.StartRecordToStorageFileAsync(
          profile, g_triangle_video_file).get();
      g_triangle_video_recording = true;
      return winrt::to_string(g_triangle_video_file.Path());
    } catch (winrt::hresult_error const& error) {
      CleanupTriangleRecorderState();
      if (error_message != nullptr) {
        *error_message = winrt::to_string(error.message());
      }
      return std::nullopt;
    } catch (std::exception const& error) {
      CleanupTriangleRecorderState();
      if (error_message != nullptr) {
        *error_message = error.what();
      }
      return std::nullopt;
    }
  });
}

std::optional<std::string> StopTriangleVideoRecording(std::string* error_message) {
  return RunTriangleRecorderTask([error_message]() -> std::optional<std::string> {
    std::scoped_lock lock(g_triangle_video_recorder_mutex);

    if (!g_triangle_video_recording || !g_triangle_video_capture ||
        !g_triangle_video_file) {
      if (error_message != nullptr) {
        *error_message = "Triangle video recorder is not running.";
      }
      return std::nullopt;
    }

    try {
      const auto recorded_path = winrt::to_string(g_triangle_video_file.Path());
      g_triangle_video_capture.StopRecordAsync().get();
      CleanupTriangleRecorderState();
      return recorded_path;
    } catch (winrt::hresult_error const& error) {
      CleanupTriangleRecorderState();
      if (error_message != nullptr) {
        *error_message = winrt::to_string(error.message());
      }
      return std::nullopt;
    } catch (std::exception const& error) {
      CleanupTriangleRecorderState();
      if (error_message != nullptr) {
        *error_message = error.what();
      }
      return std::nullopt;
    }
  });
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

void FlutterWindow::RegisterTriangleVideoRecorderChannel() {
  triangle_video_recorder_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          "kaftar/triangle_video_recorder",
          &flutter::StandardMethodCodec::GetInstance());

  triangle_video_recorder_channel_->SetMethodCallHandler(
      [this](const auto& call, auto result) {
        HandleTriangleVideoRecorderMethodCall(call, std::move(result));
      });
}

void FlutterWindow::HandleTriangleVideoRecorderMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  std::string error_message;

  if (method_call.method_name() == "startTriangleVideoRecording") {
    auto recorded_path = StartTriangleVideoRecording(&error_message);
    if (!recorded_path.has_value()) {
      result->Error("triangle_video_start_failed", error_message);
      return;
    }
    result->Success(flutter::EncodableValue(recorded_path.value()));
    return;
  }

  if (method_call.method_name() == "stopTriangleVideoRecording") {
    auto recorded_path = StopTriangleVideoRecording(&error_message);
    if (!recorded_path.has_value()) {
      result->Error("triangle_video_stop_failed", error_message);
      return;
    }
    result->Success(flutter::EncodableValue(recorded_path.value()));
    return;
  }

  result->NotImplemented();
}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  RegisterTriangleVideoRecorderChannel();
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  RunTriangleRecorderTask([]() {
    std::scoped_lock lock(g_triangle_video_recorder_mutex);
    CleanupTriangleRecorderState();
  });
  ShutdownTriangleRecorderWorker();
  triangle_video_recorder_channel_.reset();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
