#ifndef SHOPIKAISS_RAW_PRINTER_H_
#define SHOPIKAISS_RAW_PRINTER_H_
#include <windows.h>
#include <winspool.h>
#include <cstdint>
#include <string>
#include <vector>

struct RawPrintResult {
  std::string status;
  DWORD error = 0;
};

// Injectable spooler API: tests never send a document to a real printer.
struct RawSpooler {
  virtual ~RawSpooler() = default;
  virtual bool Open(const std::wstring& name) = 0;
  virtual bool Start() = 0;
  virtual bool Write(const uint8_t* bytes, DWORD size, DWORD& written) = 0;
  virtual bool End() = 0;
  virtual void Abort() = 0;
  virtual void Close() = 0;
  virtual DWORD Error() = 0;
};

inline RawPrintResult SendRaw(RawSpooler& api, const std::wstring& name,
                              const std::vector<uint8_t>& data) {
  if (name.empty() || name.size() > 1024 || name.find(L'\0') != std::wstring::npos ||
      data.empty() || data.size() > 1024 * 1024) return {"not_sent", ERROR_INVALID_PARAMETER};
  if (!api.Open(name)) return {"not_sent", api.Error()};
  if (!api.Start()) {
    const auto error = api.Error(); api.Close(); return {"not_sent", error};
  }
  DWORD written = 0;
  // Once WritePrinter is entered, even a failure can have printed bytes.
  if (!api.Write(data.data(), static_cast<DWORD>(data.size()), written) || written != data.size()) {
    const auto error = api.Error(); api.Abort(); api.Close(); return {"unknown", error};
  }
  if (!api.End()) {
    const auto error = api.Error(); api.Abort(); api.Close(); return {"unknown", error};
  }
  api.Close();
  return {"transmitted", 0};
}

class WindowsRawSpooler : public RawSpooler {
 public:
  bool Open(const std::wstring& name) override {
    return OpenPrinterW(const_cast<wchar_t*>(name.c_str()), &handle_, nullptr) != FALSE;
  }
  bool Start() override {
    wchar_t title[] = L"Shopikaiss - ticket";
    wchar_t type[] = L"RAW";
    DOC_INFO_1W doc{title, nullptr, type};
    // RAW already contains line/page/cut commands; no driver-rendered page.
    return StartDocPrinterW(handle_, 1, reinterpret_cast<LPBYTE>(&doc)) != 0;
  }
  bool Write(const uint8_t* bytes, DWORD size, DWORD& written) override {
    return WritePrinter(handle_, const_cast<uint8_t*>(bytes), size, &written) != FALSE;
  }
  bool End() override { return EndDocPrinter(handle_) != FALSE; }
  void Abort() override { AbortPrinter(handle_); }
  void Close() override { ClosePrinter(handle_); handle_ = nullptr; }
  DWORD Error() override { return GetLastError(); }
 private:
  HANDLE handle_ = nullptr;
};
#endif
