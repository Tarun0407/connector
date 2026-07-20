#ifndef RUNNER_CONNECTOR_PLATFORM_CHANNEL_H_
#define RUNNER_CONNECTOR_PLATFORM_CHANNEL_H_

#include <flutter/flutter_engine.h>
#include <windows.h>
#include <string>
#include <vector>

void RegisterConnectorPlatformChannel(flutter::FlutterEngine* engine);
void SetMainWindowHandle(HWND hwnd);
void HandleIncomingFiles(const std::vector<std::string>& filePaths);

#endif  // RUNNER_CONNECTOR_PLATFORM_CHANNEL_H_
