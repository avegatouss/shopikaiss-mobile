#include "customer_display.h"
#include <chrono>
#include <iostream>

struct CustomerDisplayPreview {
  static void Save(CustomerDisplay& display, const wchar_t* path) {
    const int width=1280, height=800;
    HDC dc=CreateCompatibleDC(nullptr);
    BITMAPINFO info{}; info.bmiHeader.biSize=sizeof(BITMAPINFOHEADER);
    info.bmiHeader.biWidth=width; info.bmiHeader.biHeight=-height;
    info.bmiHeader.biPlanes=1; info.bmiHeader.biBitCount=32; info.bmiHeader.biCompression=BI_RGB;
    void* pixels=nullptr;
    HBITMAP bitmap=CreateDIBSection(dc,&info,DIB_RGB_COLORS,&pixels,nullptr,0);
    auto old=SelectObject(dc,bitmap);
    display.Paint(dc,{0,0,width,height}); GdiFlush();
    BITMAPFILEHEADER header{}; header.bfType=0x4d42;
    header.bfOffBits=sizeof(header)+sizeof(BITMAPINFOHEADER);
    header.bfSize=header.bfOffBits+width*height*4;
    HANDLE file=CreateFileW(path,GENERIC_WRITE,0,nullptr,CREATE_ALWAYS,FILE_ATTRIBUTE_NORMAL,nullptr);
    DWORD written;
    WriteFile(file,&header,sizeof(header),&written,nullptr);
    WriteFile(file,&info.bmiHeader,sizeof(BITMAPINFOHEADER),&written,nullptr);
    WriteFile(file,pixels,width*height*4,&written,nullptr); CloseHandle(file);
    SelectObject(dc,old); DeleteObject(bitmap); DeleteDC(dc);
  }
};
int main(int argc, char**) {
  CustomerDisplay display;
  if (argc>1) {
    display.Update(L"SHOPIKAISS\n2\tCaf\u00e9 arabica moulu\t5 000 F\n1\tPain complet aux c\u00e9r\u00e9ales\t1 500 F\n3\tJus de gingembre\t3 000 F\nTOTAL : 9 500 F", "");
    CustomerDisplayPreview::Save(display, L"build/customer-display-preview.bmp");
    display.Update(L"SHOPIKAISS\nBienvenue", "");
    CustomerDisplayPreview::Save(display, L"build/customer-display-welcome.bmp");
  }
  // Deliberately nonexistent device, no real COM port is touched.
  display.ConfigureSerial(L"SHOPIKAISS_NONEXISTENT_TEST_DEVICE", 9600);
  display.Update(L"TEST", "TEST");
  for (int i = 0; i < 100 && display.Error().empty(); ++i) {
    std::this_thread::sleep_for(std::chrono::milliseconds(10));
  }
  if (display.Error().empty()) { std::cerr << "Missing serial error"; return 1; }
  display.CloseScreen();
  display.ConfigureSerial(L"", 9600);
  // Destructor must wake and join the waiting writer without deadlock.
  std::cout << "Display worker failure and shutdown PASS\n";
  return 0;
}
