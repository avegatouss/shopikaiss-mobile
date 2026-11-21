#include "platform_channel.h"
#include "secret_protection.h"
#include "customer_display.h"
#include "raw_printer.h"
#include <thread>
#include <mutex>
#include <map>
#include <regex>
#include <windows.h>
#include <shlobj.h>
#include <wincrypt.h>
#include <flutter/standard_method_codec.h>
#include <filesystem>
#include <vector>

namespace {
struct RawJobs {
  std::mutex mutex;
  int sequence = 0;
  std::map<std::string, RawPrintResult> jobs;
};
std::wstring Wide(const std::string& text) {
  const int size = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text.data(), static_cast<int>(text.size()), nullptr, 0);
  if (size <= 0) return {};
  std::wstring result(size, L'\0');
  MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text.data(), static_cast<int>(text.size()), result.data(), size);
  return result;
}
std::string Utf8(const std::wstring& value) {
  const int length = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS,
      value.data(), static_cast<int>(value.size()), nullptr, 0, nullptr, nullptr);
  if (length <= 0) return {};
  std::string output(length, '\0');
  WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value.data(),
      static_cast<int>(value.size()), output.data(), length, nullptr, nullptr);
  return output;
}
}  // namespace

std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
CreatePlatformChannel(flutter::BinaryMessenger* messenger, HWND window) {
  auto channel = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "ci.khoga.shopikaiss/windows",
      &flutter::StandardMethodCodec::GetInstance());
  channel->SetMethodCallHandler([window, raw = std::make_shared<RawJobs>(), display = std::make_shared<CustomerDisplay>(), fullscreen = false,
      saved = WINDOWPLACEMENT{sizeof(WINDOWPLACEMENT)}, style = LONG_PTR{0}](const auto& call, auto result) mutable {
    if (call.method_name() == "startRawPrint") {
      const auto* args = call.arguments() ? std::get_if<flutter::EncodableMap>(call.arguments()) : nullptr;
      const std::string* name = nullptr;
      const std::vector<uint8_t>* bytes = nullptr;
      if (args) {
        auto n = args->find(flutter::EncodableValue("printer"));
        auto b = args->find(flutter::EncodableValue("bytes"));
        if (n != args->end()) name = std::get_if<std::string>(&n->second);
        if (b != args->end()) bytes = std::get_if<std::vector<uint8_t>>(&b->second);
      }
      if (!name || !bytes || name->empty() || name->size() > 4096 || name->find('\0') != std::string::npos ||
          bytes->empty() || bytes->size() > 1024 * 1024) {
        result->Error("raw_not_sent", "Ticket ou imprimante invalide."); return;
      }
      const auto printer = Wide(*name);
      if (printer.empty()) { result->Error("raw_not_sent", "Nom imprimante invalide."); return; }
      std::string id;
      {
        std::lock_guard<std::mutex> lock(raw->mutex);
        // Bound hung spooler calls without blocking the UI thread.
        size_t pending = 0;
        for (const auto& job : raw->jobs) if (job.second.status == "pending") ++pending;
        if (pending >= 4) { result->Error("raw_not_sent", "Impressions en attente : verifier le spouleur."); return; }
        if (raw->jobs.size() >= 64) {
          for (auto it = raw->jobs.begin(); it != raw->jobs.end();) {
            if (it->second.status != "pending") it = raw->jobs.erase(it); else ++it;
          }
        }
        id = std::to_string(++raw->sequence);
        raw->jobs[id] = {"pending", 0};
      }
      try {
        std::thread([raw, id, printer, data = *bytes]() {
          WindowsRawSpooler spooler;
          const auto outcome = SendRaw(spooler, printer, data);
          std::lock_guard<std::mutex> lock(raw->mutex);
          raw->jobs[id] = outcome;
        }).detach();
      } catch (...) {
        std::lock_guard<std::mutex> lock(raw->mutex);
        raw->jobs.erase(id);
        result->Error("raw_not_sent", "Impression indisponible."); return;
      }
      result->Success(flutter::EncodableValue(id)); return;
    }
    if (call.method_name() == "rawPrintStatus") {
      const auto* id = call.arguments() ? std::get_if<std::string>(call.arguments()) : nullptr;
      std::lock_guard<std::mutex> lock(raw->mutex);
      const auto found = id ? raw->jobs.find(*id) : raw->jobs.end();
      if (found == raw->jobs.end()) { result->Success(flutter::EncodableValue("unknown")); return; }
      result->Success(flutter::EncodableValue(found->second.status)); return;
    }
    if (call.method_name() == "displayMonitors") {
      flutter::EncodableList list;
      const auto monitors = CustomerDisplay::Monitors();
      for (size_t i = 0; i < monitors.size(); ++i) {
        if (monitors[i] != MonitorFromWindow(window, MONITOR_DEFAULTTONEAREST)) list.push_back(flutter::EncodableValue(static_cast<int>(i)));
      }
      result->Success(flutter::EncodableValue(list)); return;
    }
    if (call.method_name() == "displayError") { result->Success(flutter::EncodableValue(display->Error())); return; }
    if (call.method_name() == "configureDisplay" || call.method_name() == "updateDisplay") {
      const auto* args = call.arguments() ? std::get_if<flutter::EncodableMap>(call.arguments()) : nullptr;
      if (!args) { result->Error("display_args", "Configuration invalide."); return; }
      const auto text = [args](const char* key) -> std::string {
        const auto it = args->find(flutter::EncodableValue(key));
        if (it == args->end()) return {};
        const auto* value = std::get_if<std::string>(&it->second); return value ? *value : "";
      };
      if (call.method_name() == "updateDisplay") {
        const auto screen = text("screen"), serial = text("serial");
        if (screen.size() > 8192 || serial.size() > 128) { result->Error("display_args", "Affichage trop long."); return; }
        display->Update(Wide(screen), serial); result->Success(); return;
      }
      display->CloseScreen(); display->ConfigureSerial(L"", 9600);
      const auto mode = text("mode");
      if (mode == "screen") {
        const auto index = text("monitor");
        if (!std::regex_match(index, std::regex("[0-9]{1,2}")) || !display->Screen(window, std::stoi(index))) {
          result->Error("display_monitor", "Selectionnez un second ecran etendu, distinct de la caisse."); return;
        }
      } else if (mode == "serial") {
        const auto port = text("port"), baud = text("baud");
        if (!std::regex_match(port, std::regex("COM[1-9][0-9]{0,2}")) ||
            !std::regex_match(baud, std::regex("9600|19200|38400|115200"))) {
          result->Error("display_serial", "Port COM ou vitesse invalide."); return;
        }
        display->ConfigureSerial(Wide(port), static_cast<DWORD>(std::stoul(baud)));
      } else if (mode != "off") { result->Error("display_mode", "Mode inconnu."); return; }
      result->Success(); return;
    }
    if (call.method_name() == "closeWindow") {
      result->Success();
      PostMessage(window, WM_CLOSE, 0, 0);
      return;
    }
    if (call.method_name() == "toggleFullscreen") {
      if (!fullscreen) {
        saved.length = sizeof(WINDOWPLACEMENT);
        MONITORINFO monitor{sizeof(MONITORINFO)};
        if (!GetWindowPlacement(window, &saved) || !GetMonitorInfo(MonitorFromWindow(window, MONITOR_DEFAULTTONEAREST), &monitor)) {
          result->Error("fullscreen", "Plein ecran indisponible."); return;
        }
        style = GetWindowLongPtr(window, GWL_STYLE);
        SetWindowLongPtr(window, GWL_STYLE, style & ~WS_OVERLAPPEDWINDOW);
        SetWindowPos(window, nullptr, monitor.rcMonitor.left, monitor.rcMonitor.top,
          monitor.rcMonitor.right - monitor.rcMonitor.left,
          monitor.rcMonitor.bottom - monitor.rcMonitor.top, SWP_NOZORDER | SWP_FRAMECHANGED);
      } else {
        SetWindowLongPtr(window, GWL_STYLE, style);
        SetWindowPlacement(window, &saved);
        SetWindowPos(window, nullptr, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_FRAMECHANGED);
      }
      fullscreen = !fullscreen;
      result->Success(flutter::EncodableValue(fullscreen)); return;
    }
    if (call.method_name() == "dataDirectory") {
      PWSTR local = nullptr;
      if (FAILED(SHGetKnownFolderPath(FOLDERID_LocalAppData, KF_FLAG_CREATE,
                                      nullptr, &local))) {
        result->Error("storage_path", "Stockage utilisateur indisponible.");
        return;
      }
      const std::filesystem::path path =
          std::filesystem::path(local) / L"KHOGA" / L"Shopikaiss" / L"Windows";
      CoTaskMemFree(local);
      std::error_code error;
      std::filesystem::create_directories(path, error);
      if (error) {
        result->Error("storage_path", "Impossible de preparer le stockage local.");
        return;
      }
      result->Success(flutter::EncodableValue(Utf8(path.wstring())));
      return;
    }
    if (call.method_name() == "protect" || call.method_name() == "unprotect") {
      const auto* bytes = call.arguments() == nullptr ? nullptr
          : std::get_if<std::vector<uint8_t>>(call.arguments());
      if (bytes == nullptr) {
        result->Error("invalid_secret", "Donnees de protection invalides.");
        return;
      }
      std::vector<uint8_t> value;
      const bool ok = ProtectLocalSecret(*bytes, value,
                                         call.method_name() == "unprotect");
      if (!ok) {
        result->Error("secret_protection", "Protection utilisateur indisponible.");
        return;
      }
      result->Success(flutter::EncodableValue(value));
      SecureZeroMemory(value.data(), value.size());
      return;
    }
    result->NotImplemented();
  });
  return channel;
}
