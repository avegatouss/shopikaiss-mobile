#include "secret_protection.h"
#include "instance_lock.h"
#include <iostream>
#include <stdexcept>
#include <string>

void Require(bool condition, const char* message) {
  if (!condition) throw std::runtime_error(message);
}

DWORD ChildLockExit() {
  wchar_t path[32768];
  Require(GetModuleFileNameW(nullptr, path, 32768) != 0, "executable path");
  std::wstring command = L"\"" + std::wstring(path) + L"\" --lock-child";
  STARTUPINFOW startup{};
  startup.cb = sizeof(startup);
  PROCESS_INFORMATION process{};
  Require(CreateProcessW(path, command.data(), nullptr, nullptr, FALSE,
      CREATE_NO_WINDOW, nullptr, nullptr, &startup, &process) != FALSE,
      "child launch");
  CloseHandle(process.hThread);
  const DWORD waited = WaitForSingleObject(process.hProcess, 5000);
  if (waited != WAIT_OBJECT_0) {
    TerminateProcess(process.hProcess, 99);
    CloseHandle(process.hProcess);
    throw std::runtime_error("child timeout");
  }
  DWORD code = 99;
  GetExitCodeProcess(process.hProcess, &code);
  CloseHandle(process.hProcess);
  return code;
}

int main(int argc, char**) {
  if (argc > 1) {
    InstanceLock lock;
    return lock.Acquire() ? 0 : 23;
  }
  try {
    std::vector<uint8_t> clear{0, 1, 2, 255, 0, 42};
    std::vector<uint8_t> encrypted, restored;
    Require(ProtectLocalSecret(clear, encrypted, false), "DPAPI protect");
    Require(encrypted != clear, "ciphertext differs");
    Require(ProtectLocalSecret(encrypted, restored, true) && restored == clear,
            "DPAPI roundtrip");
    encrypted[encrypted.size() / 2] ^= 0xff;
    Require(!ProtectLocalSecret(encrypted, restored, true) && restored.empty(),
            "tamper rejection clears previous plaintext");
    clear.assign(65536, 42);
    Require(ProtectLocalSecret(clear, encrypted, false), "maximum plaintext");
    Require(encrypted.size() > clear.size(), "DPAPI envelope overhead");
    Require(ProtectLocalSecret(encrypted, restored, true) && restored == clear,
            "maximum plaintext roundtrip");
    clear.push_back(42);
    Require(!ProtectLocalSecret(clear, encrypted, false), "oversize rejected");
    Require(!ProtectLocalSecret({}, restored, false), "empty rejected");
    {
      InstanceLock first;
      Require(first.Acquire(), "first instance (close running caisse first)");
      Require(!first.Acquire(), "repeat acquire rejected");
      Require(ChildLockExit() == 23, "second process denied");
    }
    Require(ChildLockExit() == 0, "lock released after owner closes");
    std::cout << "PASS: DPAPI roundtrip, corruption, limits; process exclusion and release\n";
    return 0;
  } catch (const std::exception& error) {
    std::cerr << "FAIL: " << error.what() << '\n';
    return 1;
  }
}
