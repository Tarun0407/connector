#ifndef RUNNER_CONNECTOR_PLATFORM_CHANNEL_H_
#define RUNNER_CONNECTOR_PLATFORM_CHANNEL_H_

#include <flutter/flutter_engine.h>
#include <windows.h>

void RegisterConnectorPlatformChannel(flutter::FlutterEngine* engine);
void SetMainWindowHandle(HWND hwnd);

#endif  // RUNNER_CONNECTOR_PLATFORM_CHANNEL_H_
