#ifndef SHOPIKAISS_PLATFORM_CHANNEL_H_
#define SHOPIKAISS_PLATFORM_CHANNEL_H_
#include <flutter/method_channel.h>
#include <flutter/encodable_value.h>
#include <memory>
#include <windows.h>

std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
CreatePlatformChannel(flutter::BinaryMessenger* messenger, HWND window);
#endif
