#include "platform_channel.h"
#include "secret_protection.h"
#include <windows.h>
#include <shlobj.h>
#include <wincrypt.h>
#include <flutter/standard_method_codec.h>
#include <filesystem>
#include <vector>

namespace {
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
  channel->SetMethodCallHandler([window, fullscreen = false,
      saved = WINDOWPLACEMENT{sizeof(WINDOWPLACEMENT)}, style = LONG_PTR{0}](const auto& call, auto result) mutable {
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
