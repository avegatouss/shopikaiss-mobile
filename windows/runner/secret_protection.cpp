#include "secret_protection.h"
#include <windows.h>
#include <wincrypt.h>

bool ProtectLocalSecret(const std::vector<uint8_t>& input,
                        std::vector<uint8_t>& output, bool decrypt) {
  if (!output.empty()) SecureZeroMemory(output.data(), output.size());
  output.clear();
  // DPAPI adds metadata; accept its envelope above the plaintext limit.
  const size_t limit = decrypt ? 131072 : 65536;
  if (input.empty() || input.size() > limit) return false;
  DATA_BLOB source{static_cast<DWORD>(input.size()),
                   const_cast<BYTE*>(input.data())};
  DATA_BLOB result{};
  const BOOL ok = decrypt
      ? CryptUnprotectData(&source, nullptr, nullptr, nullptr, nullptr,
                           CRYPTPROTECT_UI_FORBIDDEN, &result)
      : CryptProtectData(&source, L"Shopikaiss", nullptr, nullptr, nullptr,
                         CRYPTPROTECT_UI_FORBIDDEN, &result);
  if (!ok) return false;
  const bool valid = !decrypt || result.cbData <= 65536;
  if (valid) output.assign(result.pbData, result.pbData + result.cbData);
  SecureZeroMemory(result.pbData, result.cbData);
  LocalFree(result.pbData);
  return valid;
}
