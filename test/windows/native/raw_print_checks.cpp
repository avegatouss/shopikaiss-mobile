#include "raw_printer.h"
#include <iostream>

struct Fake : RawSpooler {
  int fail = 0, writes = 0, aborted = 0, closed = 0;
  bool Open(const std::wstring&) override { return fail != 1; }
  bool Start() override { return fail != 2; }
  bool Write(const uint8_t*, DWORD size, DWORD& written) override {
    ++writes; written = fail == 3 ? size - 1 : size; return fail != 4;
  }
  bool End() override { return fail != 5; }
  void Abort() override { ++aborted; }
  void Close() override { ++closed; }
  DWORD Error() override { return 123; }
};
int main() {
  for (int failure = 0; failure <= 5; ++failure) {
    Fake api; api.fail = failure;
    auto result = SendRaw(api, L"POS-80", {27, 64, 65, 10});
    const std::string expected = failure == 0 ? "transmitted" : (failure <= 2 ? "not_sent" : "unknown");
    if (result.status != expected || api.writes != (failure == 1 || failure == 2 ? 0 : 1) ||
        api.closed != (failure == 1 ? 0 : 1) || api.aborted != (failure >= 3 ? 1 : 0)) return 1;
  }
  Fake api;
  if (SendRaw(api, L"", {65}).status != "not_sent" || api.writes != 0) return 2;
  std::cout << "PASS: spooler success, open/start failure, partial/failed write, end failure; no real print\n";
  return 0;
}
