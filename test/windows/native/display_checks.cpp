#include "customer_display.h"
#include <chrono>
#include <iostream>

int main() {
  CustomerDisplay display;
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
