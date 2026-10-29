#include "instance_lock.h"
#include <sddl.h>
#include <string>
#include <vector>

bool InstanceLock::Acquire() {
  HANDLE token = nullptr;
  if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token)) return false;
  DWORD size = 0;
  GetTokenInformation(token, TokenUser, nullptr, 0, &size);
  std::vector<BYTE> buffer(size);
  const BOOL read = GetTokenInformation(token, TokenUser, buffer.data(), size, &size);
  CloseHandle(token);
  if (!read) return false;
  LPWSTR raw_sid = nullptr;
  if (!ConvertSidToStringSidW(reinterpret_cast<TOKEN_USER*>(buffer.data())->User.Sid,
                             &raw_sid)) return false;
  const std::wstring sid(raw_sid);
  LocalFree(raw_sid);
  const std::wstring name = L"Local\\Shopikaiss.Caisse.Windows." + sid;
  const std::wstring acl = L"D:P(A;;GA;;;" + sid + L")";
  PSECURITY_DESCRIPTOR descriptor = nullptr;
  if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(
      acl.c_str(), SDDL_REVISION_1, &descriptor, nullptr)) return false;
  SECURITY_ATTRIBUTES attributes{sizeof(SECURITY_ATTRIBUTES), descriptor, FALSE};
  handle_ = CreateMutexW(&attributes, FALSE, name.c_str());
  const DWORD error = GetLastError();
  LocalFree(descriptor);
  return handle_ != nullptr && error != ERROR_ALREADY_EXISTS;
}
