#pragma once
#include <windows.h>
#include <condition_variable>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

// Serial writes never run on the cashier/UI thread. Only the newest frame matters.
class CustomerDisplay {
 public:
  CustomerDisplay() : worker_([this] { Run(); }) {}
  ~CustomerDisplay() {
    { std::lock_guard<std::mutex> lock(mutex_); stop_ = true; }
    wake_.notify_one(); worker_.join(); CloseScreen();
  }
  static std::vector<HMONITOR> Monitors() {
    std::vector<HMONITOR> monitors;
    EnumDisplayMonitors(nullptr, nullptr, [](HMONITOR monitor, HDC, LPRECT, LPARAM data) -> BOOL {
      reinterpret_cast<std::vector<HMONITOR>*>(data)->push_back(monitor); return TRUE;
    }, reinterpret_cast<LPARAM>(&monitors));
    return monitors;
  }
  bool Screen(HWND owner, int index) {
    const auto monitors = Monitors();
    if (index < 0 || static_cast<size_t>(index) >= monitors.size() ||
        monitors[index] == MonitorFromWindow(owner, MONITOR_DEFAULTTONEAREST)) return false;
    MONITORINFO info{sizeof(MONITORINFO)};
    if (!GetMonitorInfo(monitors[index], &info)) return false;
    CloseScreen();
    screen_ = CreateWindowEx(WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE, L"STATIC", L"SHOPIKAISS\r\nBienvenue",
      WS_POPUP | SS_CENTER, info.rcMonitor.left, info.rcMonitor.top,
      info.rcMonitor.right-info.rcMonitor.left, info.rcMonitor.bottom-info.rcMonitor.top,
      owner, nullptr, GetModuleHandle(nullptr), nullptr);
    if (!screen_) return false;
    font_ = CreateFontW(32, 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE, DEFAULT_CHARSET,
      OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY, DEFAULT_PITCH, L"Segoe UI");
    SendMessage(screen_, WM_SETFONT, reinterpret_cast<WPARAM>(font_), TRUE);
    ShowWindow(screen_, SW_SHOWNOACTIVATE); return true;
  }
  void CloseScreen() {
    if (screen_ && IsWindow(screen_)) DestroyWindow(screen_);
    screen_ = nullptr;
    if (font_) DeleteObject(font_);
    font_ = nullptr;
  }
  void ConfigureSerial(const std::wstring& port, DWORD baud) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!port_.empty() && port.empty()) {
      pending_port_ = port_; pending_baud_ = baud_;
      pending_ = "\x0c\x1b\x40SHOPIKAISS          Bienvenue           ";
      wake_.notify_one();
    }
    port_ = port; baud_ = baud; error_.clear();
  }
  void Update(const std::wstring& screen, const std::string& serial) {
    if (screen_ && IsWindow(screen_)) SetWindowTextW(screen_, screen.c_str());
    { std::lock_guard<std::mutex> lock(mutex_); if (!port_.empty()) {
      pending_ = serial; pending_port_ = port_; pending_baud_ = baud_;
    } }
    wake_.notify_one();
  }
  std::string Error() { std::lock_guard<std::mutex> lock(mutex_); return error_; }
 private:
  void Run() {
    for (;;) {
      std::wstring port; std::string bytes; DWORD baud;
      { std::unique_lock<std::mutex> lock(mutex_);
        wake_.wait(lock, [this] { return stop_ || !pending_.empty(); });
        if (stop_) return;
        port = pending_port_; baud = pending_baud_; bytes.swap(pending_);
      }
      const HANDLE handle = CreateFileW((L"\\\\.\\" + port).c_str(), GENERIC_WRITE, 0, nullptr,
        OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
      bool ok = handle != INVALID_HANDLE_VALUE;
      if (ok) {
        DCB dcb{}; dcb.DCBlength = sizeof(DCB);
        ok = GetCommState(handle, &dcb) != FALSE;
        dcb.BaudRate = baud; dcb.ByteSize = 8; dcb.Parity = NOPARITY; dcb.StopBits = ONESTOPBIT;
        dcb.fBinary = TRUE; dcb.fParity = FALSE; dcb.fOutxCtsFlow = FALSE; dcb.fOutxDsrFlow = FALSE;
        dcb.fOutX = FALSE; dcb.fInX = FALSE; dcb.fDtrControl = DTR_CONTROL_ENABLE;
        dcb.fRtsControl = RTS_CONTROL_ENABLE; dcb.fAbortOnError = FALSE;
        COMMTIMEOUTS timeouts{}; timeouts.WriteTotalTimeoutConstant = 150;
        ok = ok && SetCommState(handle, &dcb) && SetCommTimeouts(handle, &timeouts);
        DWORD written = 0;
        if (ok) ok = WriteFile(handle, bytes.data(), static_cast<DWORD>(bytes.size()), &written, nullptr) && written == bytes.size();
        CloseHandle(handle);
      }
      { std::lock_guard<std::mutex> lock(mutex_); error_ = ok ? "" : "Afficheur serie indisponible : verifier port, connexion et protocole."; }
    }
  }
  HWND screen_ = nullptr;
  HFONT font_ = nullptr;
  std::mutex mutex_;
  std::condition_variable wake_;
  bool stop_ = false;
  std::wstring port_;
  std::wstring pending_port_;
  DWORD baud_ = 9600;
  DWORD pending_baud_ = 9600;
  std::string pending_, error_;
  std::thread worker_;
};
