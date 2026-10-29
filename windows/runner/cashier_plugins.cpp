#include "cashier_plugins.h"
#include <permission_handler_windows/permission_handler_windows_plugin.h>
#include <printing/printing_plugin.h>
#include <url_launcher_windows/url_launcher_windows.h>

// This runner hosts the native local cashier, never the legacy remote WebView.
// Keep the generated registrant untouched for dependency inventory. The pinned
// WebView plugin creates a DispatcherQueue even without a WebView and fails on
// shutdown on the tested Windows 10 host (coremessaging, 0xc0000602).
// A future WebView feature requires an explicit plugin lifecycle qualification.
void RegisterCashierPlugins(flutter::PluginRegistry* registry) {
  PermissionHandlerWindowsPluginRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("PermissionHandlerWindowsPlugin"));
  PrintingPluginRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("PrintingPlugin"));
  UrlLauncherWindowsRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("UrlLauncherWindows"));
}
