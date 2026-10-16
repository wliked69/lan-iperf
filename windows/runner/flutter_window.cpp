#include "flutter_window.h"

#include <optional>
#include <vector>
#include <algorithm>
#include <flutter/standard_method_codec.h>
#include "network_discovery.h"

#include "flutter/generated_plugin_registrant.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

void FlutterWindow::StopServer() {
  if (server_job_) { CloseHandle(server_job_); server_job_ = nullptr; }
  if (server_output_) { CloseHandle(server_output_); server_output_ = nullptr; }
  if (server_process_) {
    WaitForSingleObject(server_process_, 2000);
    CloseHandle(server_process_); server_process_ = nullptr;
  }
}

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
  network_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
    flutter_controller_->engine()->messenger(), "cn.lanperf/network",
    &flutter::StandardMethodCodec::GetInstance());
  network_channel_->SetMethodCallHandler([](const auto& call, auto result) {
    if (call.method_name() != "networks" && call.method_name() != "connections") { result->NotImplemented(); return; }
    uint32_t error = 0;
    const auto networks = call.method_name() == "connections" ? ReadConnectionInfo(&error) : ReadLocalNetworks(&error);
    if (error != 0) { result->Error("NETWORK", "Cannot enumerate local networks: " + std::to_string(error)); }
    else { result->Success(flutter::EncodableValue(networks)); }
  });
  server_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
    flutter_controller_->engine()->messenger(), "cn.lanperf/server",
    &flutter::StandardMethodCodec::GetInstance());
  server_channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    if (call.method_name() == "stop") { StopServer(); result->Success(); return; }
    if (call.method_name() == "poll") {
      std::string output;
      DWORD available = 0;
      while (server_output_ && output.size() < 262144 &&
          PeekNamedPipe(server_output_, nullptr, 0, nullptr, &available, nullptr) && available) {
        char chunk[8192]; DWORD count = 0;
        if (!ReadFile(server_output_, chunk, (std::min)(available, static_cast<DWORD>(sizeof(chunk))), &count, nullptr) || !count) break;
        output.append(chunk, count);
      }
      result->Success(flutter::EncodableValue(output)); return;
    }
    if (call.method_name() == "status") {
      DWORD code = 0;
      const bool running = server_process_ && GetExitCodeProcess(server_process_, &code) && code == STILL_ACTIVE;
      result->Success(flutter::EncodableValue(running)); return;
    }
    if (call.method_name() != "start") { result->NotImplemented(); return; }
    const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
    if (!args) { result->Error("CONFIG", "Missing server settings"); return; }
    const auto port_it = args->find(flutter::EncodableValue("port"));
    const auto binary_it = args->find(flutter::EncodableValue("binary"));
    const auto* port = port_it == args->end() ? nullptr : std::get_if<int32_t>(&port_it->second);
    const auto* binary = binary_it == args->end() ? nullptr : std::get_if<std::string>(&binary_it->second);
    if (!port || *port < 1 || *port > 65535 || !binary || binary->find('"') != std::string::npos) {
      result->Error("CONFIG", "Invalid server settings"); return;
    }
    StopServer();
    std::wstring executable;
    if (binary->empty()) {
      wchar_t path[32768];
      const DWORD length = GetModuleFileNameW(nullptr, path, 32768);
      executable.assign(path, length);
      executable = executable.substr(0, executable.find_last_of(L"\\/") + 1) + L"iperf3.exe";
    } else {
      const int size = MultiByteToWideChar(CP_UTF8, 0, binary->data(), static_cast<int>(binary->size()), nullptr, 0);
      executable.resize(size);
      MultiByteToWideChar(CP_UTF8, 0, binary->data(), static_cast<int>(binary->size()), executable.data(), size);
    }
    std::wstring command = L"\"" + executable + L"\" -s -p " + std::to_wstring(*port) + L" --json-stream --forceflush -i 0.1";
    std::vector<wchar_t> buffer(command.begin(), command.end()); buffer.push_back(0);
    server_job_ = CreateJobObjectW(nullptr, nullptr);
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits{};
    limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    if (!server_job_ || !SetInformationJobObject(server_job_, JobObjectExtendedLimitInformation, &limits, sizeof(limits))) {
      StopServer(); result->Error("SERVER", "Cannot create server job"); return;
    }
    // Cygwin needs valid descriptors 0/1/2 even without a console.
    SECURITY_ATTRIBUTES security{sizeof(SECURITY_ATTRIBUTES), nullptr, TRUE};
    HANDLE quiet = CreateFileW(L"NUL", GENERIC_READ | GENERIC_WRITE,
        FILE_SHARE_READ | FILE_SHARE_WRITE, &security, OPEN_EXISTING, 0, nullptr);
    if (quiet == INVALID_HANDLE_VALUE) {
      StopServer(); result->Error("SERVER", "Cannot open server output"); return;
    }
    HANDLE output_write = nullptr;
    if (!CreatePipe(&server_output_, &output_write, &security, 65536) ||
        !SetHandleInformation(server_output_, HANDLE_FLAG_INHERIT, 0)) {
      if (output_write) CloseHandle(output_write);
      CloseHandle(quiet); StopServer(); result->Error("SERVER", "Cannot capture server output"); return;
    }
    STARTUPINFOW startup{}; startup.cb = sizeof(startup);
    startup.dwFlags = STARTF_USESTDHANDLES;
    startup.hStdInput = quiet; startup.hStdOutput = output_write; startup.hStdError = quiet;
    PROCESS_INFORMATION process{};
    if (!CreateProcessW(executable.c_str(), buffer.data(), nullptr, nullptr, TRUE,
        CREATE_NO_WINDOW | CREATE_SUSPENDED, nullptr, nullptr, &startup, &process)) {
      const auto error = GetLastError(); CloseHandle(output_write); CloseHandle(quiet); StopServer();
      result->Error("SERVER", "Cannot launch iperf3.exe (" + std::to_string(error) + "). Check engine path and DLLs."); return;
    }
    CloseHandle(output_write);
    CloseHandle(quiet);
    server_process_ = process.hProcess;
    if (!AssignProcessToJobObject(server_job_, server_process_)) {
      TerminateProcess(server_process_, 1); CloseHandle(process.hThread); StopServer();
      result->Error("SERVER", "Cannot manage server lifetime"); return;
    }
    ResumeThread(process.hThread); CloseHandle(process.hThread);
    result->Success();
  });
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
  server_channel_.reset();
  StopServer();
  network_channel_.reset();
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
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
