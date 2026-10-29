#include "platform_channel.h"
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
CreatePlatformChannel(flutter::BinaryMessenger* messenger) {
  auto channel = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "ci.khoga.shopikaiss/windows",
      &flutter::StandardMethodCodec::GetInstance());
  channel->SetMethodCallHandler([](const auto& call, auto result) {
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
      if (bytes == nullptr || bytes->empty() || bytes->size() > 65536) {
        result->Error("invalid_secret", "Donnees de protection invalides.");
        return;
      }
      DATA_BLOB input{static_cast<DWORD>(bytes->size()),
                      const_cast<BYTE*>(bytes->data())};
      DATA_BLOB output{};
      const BOOL ok = call.method_name() == "protect"
          ? CryptProtectData(&input, L"Shopikaiss", nullptr, nullptr, nullptr,
                             CRYPTPROTECT_UI_FORBIDDEN, &output)
          : CryptUnprotectData(&input, nullptr, nullptr, nullptr, nullptr,
                               CRYPTPROTECT_UI_FORBIDDEN, &output);
      if (!ok) {
        result->Error("secret_protection", "Protection utilisateur indisponible.");
        return;
      }
      std::vector<uint8_t> value(output.pbData, output.pbData + output.cbData);
      SecureZeroMemory(output.pbData, output.cbData);
      LocalFree(output.pbData);
      result->Success(flutter::EncodableValue(value));
      SecureZeroMemory(value.data(), value.size());
      return;
    }
    result->NotImplemented();
  });
  return channel;
}
