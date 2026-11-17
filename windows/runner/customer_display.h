#pragma once
#include <windows.h>
#include <condition_variable>
#include <mutex>
#include <string>
#include <thread>
#include <vector>
#include <algorithm>
#include <sstream>

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
    WNDCLASSW wc{};
    wc.lpfnWndProc = ScreenProc; wc.hInstance = GetModuleHandle(nullptr);
    wc.lpszClassName = L"ShopikaissCustomerScreen";
    wc.hCursor = LoadCursor(nullptr, IDC_ARROW);
    RegisterClassW(&wc);
    screen_ = CreateWindowExW(WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE,
      wc.lpszClassName, L"Shopikaiss - Affichage client", WS_POPUP,
      info.rcMonitor.left, info.rcMonitor.top,
      info.rcMonitor.right-info.rcMonitor.left, info.rcMonitor.bottom-info.rcMonitor.top,
      owner, nullptr, wc.hInstance, this);
    if (!screen_) return false;
    ShowWindow(screen_, SW_SHOWNOACTIVATE); return true;
  }
  void CloseScreen() {
    if (screen_ && IsWindow(screen_)) DestroyWindow(screen_);
    screen_ = nullptr;

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
    screen_text_ = screen;
    if (screen_ && IsWindow(screen_)) InvalidateRect(screen_, nullptr, FALSE);
    { std::lock_guard<std::mutex> lock(mutex_); if (!port_.empty()) {
      pending_ = serial; pending_port_ = port_; pending_baud_ = baud_;
    } }
    wake_.notify_one();
  }
  std::string Error() { std::lock_guard<std::mutex> lock(mutex_); return error_; }
 private:
  friend struct CustomerDisplayPreview;
  static LRESULT CALLBACK ScreenProc(HWND hwnd, UINT msg, WPARAM w, LPARAM l) {
    auto self = reinterpret_cast<CustomerDisplay*>(GetWindowLongPtrW(hwnd, GWLP_USERDATA));
    if (msg == WM_NCCREATE) {
      self = static_cast<CustomerDisplay*>(reinterpret_cast<CREATESTRUCTW*>(l)->lpCreateParams);
      SetWindowLongPtrW(hwnd, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(self));
    }
    if (msg == WM_ERASEBKGND) return 1;
    if (msg == WM_PAINT && self) {
      PAINTSTRUCT ps; HDC dc = BeginPaint(hwnd, &ps);
      RECT bounds; GetClientRect(hwnd, &bounds);
      HDC buffer = CreateCompatibleDC(dc);
      HBITMAP bitmap = CreateCompatibleBitmap(dc, bounds.right, bounds.bottom);
      auto old = SelectObject(buffer, bitmap);
      self->Paint(buffer, bounds);
      BitBlt(dc, 0, 0, bounds.right, bounds.bottom, buffer, 0, 0, SRCCOPY);
      SelectObject(buffer, old); DeleteObject(bitmap); DeleteDC(buffer);
      EndPaint(hwnd, &ps); return 0;
    }
    return DefWindowProcW(hwnd, msg, w, l);
  }
  void Paint(HDC dc, RECT bounds) {
    const int width = bounds.right, height = bounds.bottom;
    const double scale = (std::max)(0.5, (std::min)(width / 1280.0, height / 800.0));
    auto px = [scale](int value) { return static_cast<int>(value * scale); };
    const COLORREF ink = RGB(30, 46, 43), muted = RGB(105, 119, 114);
    auto box = [&](RECT r, COLORREF color, bool rounded = false) {
      HBRUSH brush = CreateSolidBrush(color);
      auto oldBrush = SelectObject(dc, brush); auto oldPen = SelectObject(dc, GetStockObject(NULL_PEN));
      if (rounded) RoundRect(dc, r.left, r.top, r.right, r.bottom, px(28), px(28));
      else Rectangle(dc, r.left, r.top, r.right, r.bottom);
      SelectObject(dc, oldPen); SelectObject(dc, oldBrush); DeleteObject(brush);
    };
    auto text = [&](const std::wstring& value, RECT r, int size, COLORREF color,
                    bool bold = false, UINT align = DT_LEFT, bool fit = false) {
      HFONT font = CreateFontW(-px(size), 0, 0, 0, bold ? FW_SEMIBOLD : FW_NORMAL,
        FALSE, FALSE, FALSE, DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
        CLEARTYPE_QUALITY, DEFAULT_PITCH, L"Segoe UI");
      auto old = SelectObject(dc, font);
      if (fit) {
        SIZE extent{};
        GetTextExtentPoint32W(dc, value.c_str(), static_cast<int>(value.size()), &extent);
        while (extent.cx > r.right-r.left && size > 12) {
          SelectObject(dc, old); DeleteObject(font); --size;
          font = CreateFontW(-px(size),0,0,0,bold ? FW_SEMIBOLD : FW_NORMAL,FALSE,FALSE,FALSE,
            DEFAULT_CHARSET,OUT_DEFAULT_PRECIS,CLIP_DEFAULT_PRECIS,CLEARTYPE_QUALITY,DEFAULT_PITCH,L"Segoe UI");
          SelectObject(dc,font);
          GetTextExtentPoint32W(dc,value.c_str(),static_cast<int>(value.size()),&extent);
        }
      }
      SetTextColor(dc, color); SetBkMode(dc, TRANSPARENT);
      DrawTextW(dc, value.c_str(), -1, &r, align | DT_SINGLELINE | DT_VCENTER | DT_END_ELLIPSIS | DT_NOPREFIX);
      SelectObject(dc, old); DeleteObject(font);
    };
    box(bounds, RGB(244, 246, 243));
    const int pad = px(48), top = px(142), bottom = height - px(70);
    text(L"SHOPIKAISS", {pad, px(30), width-pad, px(78)}, 27, ink, true);
    text(L"Le plaisir de vous servir", {pad, px(78), width-pad, px(110)}, 16, muted);
    box({pad, px(123), width-pad, px(125)}, RGB(220, 226, 220));
    std::vector<std::wstring> rows;
    std::wistringstream stream(screen_text_); std::wstring line, total;
    bool test = screen_text_.find(L"TEST AFFICHEUR") != std::wstring::npos;
    while (std::getline(stream, line)) {
      if (line.rfind(L"TOTAL : ", 0) == 0) total = line.substr(8);
      else if (line.find(L'\t') != std::wstring::npos) rows.push_back(line);
    }
    if (rows.empty()) {
      box({pad, top, width-pad, bottom}, RGB(255, 255, 255), true);
      const int middle = (top + bottom) / 2;
      text(test ? L"Votre afficheur est pr\u00eat" : L"Bienvenue", {pad, middle-px(80), width-pad, middle}, 56, ink, true, DT_CENTER);
      text(test ? L"Test d'affichage \u00b7 Aucune vente" : L"Vos achats s'afficheront ici", {pad, middle+px(15), width-pad, middle+px(60)}, 24, muted, false, DT_CENTER);
      box({width/2-px(30), middle+px(90), width/2+px(30), middle+px(94)}, RGB(198, 160, 82));
    } else {
      const int split = pad + (width - 2*pad) * 65 / 100;
      const int right = split + px(24), inset = px(26);
      box({pad, top, split, bottom}, RGB(255, 255, 255), true);
      box({right, top, width-pad, bottom}, RGB(21, 59, 49), true);
      text(L"Votre panier", {pad+inset, top+px(14), split-inset, top+px(66)}, 28, ink, true);
      text(std::to_wstring(rows.size()) + L" ligne(s)", {pad+inset, top+px(62), split-inset, top+px(94)}, 16, muted);
      const int rowHeight = px(66), start = top+px(145);
      const size_t capacity = static_cast<size_t>((std::max)(1, (bottom-start-px(34))/rowHeight));
      const size_t first = rows.size() > capacity ? rows.size()-capacity : 0;
      text(L"QT\u00c9", {pad+inset, top+px(100), pad+px(90), start}, 13, muted, true);
      text(L"ARTICLE", {pad+px(100), top+px(100), split-px(160), start}, 13, muted, true);
      text(L"MONTANT", {split-px(160), top+px(100), split-inset, start}, 13, muted, true, DT_RIGHT);
      for (size_t i=first; i<rows.size(); ++i) {
        const auto a=rows[i].find(L'\t'), b=rows[i].find(L'\t', a+1);
        if (b == std::wstring::npos) continue;
        const int y = start + static_cast<int>(i-first)*rowHeight;
        if (i+1==rows.size()) box({pad+px(10), y, split-px(10), y+rowHeight-px(4)}, RGB(237, 245, 239), true);
        text(rows[i].substr(0,a), {pad+inset,y,pad+px(90),y+rowHeight}, 21, muted);
        text(rows[i].substr(a+1,b-a-1), {pad+px(100),y,split-px(170),y+rowHeight}, 22, ink, i+1==rows.size());
        text(rows[i].substr(b+1), {split-px(170),y,split-inset,y+rowHeight}, 22, ink, true, DT_RIGHT);
      }
      if (first) text(L"+ " + std::to_wstring(first) + L" ligne(s) pr\u00e9c\u00e9dente(s) incluse(s)", {pad+inset,bottom-px(32),split-inset,bottom}, 14, muted);
      text(L"TOTAL \u00c0 PAYER", {right+inset,top+px(28),width-pad-inset,top+px(65)}, 17, RGB(185, 212, 196), true);
      // Shrink long totals instead of hiding financially significant digits.
      int totalSize=48;
      if (total.size()>12) totalSize=32;
      if (total.size()>18) totalSize=24;
      text(total, {right+inset,top+px(80),width-pad-inset,top+px(160)}, totalSize, RGB(255,255,255), true, DT_LEFT, true);
      box({right+inset,top+px(190),width-pad-inset,top+px(192)}, RGB(61,91,74));
      text(L"Merci pour votre confiance", {right+inset,bottom-px(94),width-pad-inset,bottom-px(54)}, 19, RGB(236,220,177));
      text(L"Montant actualis\u00e9 en direct", {right+inset,bottom-px(55),width-pad-inset,bottom-px(24)}, 14, RGB(185,212,196));
    }
    text(L"\u00c0 bient\u00f4t chez nous", {pad,height-px(55),width-pad,height-px(15)}, 15, muted, false, DT_CENTER);
  }
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
  std::wstring screen_text_ = L"SHOPIKAISS\n\nBienvenue";
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
