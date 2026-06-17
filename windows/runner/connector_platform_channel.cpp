#include "connector_platform_channel.h"

#include <endpointvolume.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <mmdeviceapi.h>
#include <shellapi.h>
#include <windows.h>
#include <wtsapi32.h>
#include <winsock2.h>
#include <ws2tcpip.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Media.Control.h>
#include <winrt/base.h>

#include <algorithm>
#include <chrono>
#include <cstdint>
#include <future>
#include <memory>
#include <optional>
#include <sstream>
#include <string>
#include <variant>
#include <vector>
#include <thread>

#pragma comment(lib, "ws2_32.lib")

namespace {

using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;
using flutter::MethodCall;
using flutter::MethodResult;
using flutter::MethodChannel;
using flutter::StandardMethodCodec;
namespace media_control = winrt::Windows::Media::Control;

constexpr char kChannelName[] = "connector/platform";
constexpr wchar_t kRunKeyPath[] = L"Software\\Microsoft\\Windows\\CurrentVersion\\Run";
constexpr wchar_t kAutoStartValueName[] = L"Connector";
constexpr wchar_t kConnectorRegistryPath[] = L"Software\\Connector";
constexpr wchar_t kNotificationWindowClass[] = L"ConnectorNotificationWindow";
constexpr int kLocalPort = 5005;

// --- Local Network Server Logic ---

void HandleLocalClient(SOCKET clientSocket) {
    char buffer[1024] = {0};
    int bytesRead = recv(clientSocket, buffer, 1024, 0);
    if (bytesRead > 0) {
        std::string command(buffer, bytesRead);
        // Basic command mapping
        if (command == "volumeUp") SendVirtualKey(VK_VOLUME_UP);
        else if (command == "volumeDown") SendVirtualKey(VK_VOLUME_DOWN);
        else if (command == "volumeMute") SendVirtualKey(VK_VOLUME_MUTE);
        else if (command == "mediaPlayPause") SendVirtualKey(VK_MEDIA_PLAY_PAUSE);
        else if (command == "mediaNext") SendVirtualKey(VK_MEDIA_NEXT_TRACK);
        else if (command == "mediaPrevious") SendVirtualKey(VK_MEDIA_PREV_TRACK);
        else if (command == "lock") LockWorkStation();
    }
    closesocket(clientSocket);
}

void StartLocalServer() {
    std::thread([]() {
        WSADATA wsaData;
        if (WSAStartup(MAKEWORD(2, 2), &wsaData) != 0) return;

        SOCKET listenSocket = socket(AF_INET, SOCK_STREAM, 0);
        if (listenSocket == INVALID_SOCKET) return;

        sockaddr_in serverAddr = {};
        serverAddr.sin_family = AF_INET;
        serverAddr.sin_addr.s_addr = INADDR_ANY;
        serverAddr.sin_port = htons(kLocalPort);

        if (bind(listenSocket, (struct sockaddr*)&serverAddr, sizeof(serverAddr)) == SOCKET_ERROR) {
            closesocket(listenSocket);
            return;
        }

        listen(listenSocket, SOMAXCONN);

        while (true) {
            SOCKET clientSocket = accept(listenSocket, nullptr, nullptr);
            if (clientSocket != INVALID_SOCKET) {
                std::thread(HandleLocalClient, clientSocket).detach();
            }
        }
        closesocket(listenSocket);
        WSACleanup();
    }).detach();
}

LRESULT CALLBACK NotificationWindowProc(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) {
  return DefWindowProc(hwnd, message, wparam, lparam);
}

HWND NotificationHostWindow() {
  static HWND hwnd = nullptr;
  if (hwnd != nullptr) return hwnd;
  WNDCLASSW window_class = {};
  window_class.lpfnWndProc = NotificationWindowProc;
  window_class.hInstance = GetModuleHandle(nullptr);
  window_class.lpszClassName = kNotificationWindowClass;
  RegisterClassW(&window_class);
  hwnd = CreateWindowExW(0, kNotificationWindowClass, L"Connector", 0, 0, 0, 0, 0, HWND_MESSAGE, nullptr, GetModuleHandle(nullptr), nullptr);
  return hwnd;
}

std::string WideToUtf8(const std::wstring& value) {
  if (value.empty()) return "";
  const int size = WideCharToMultiByte(CP_UTF8, 0, value.data(), static_cast<int>(value.size()), nullptr, 0, nullptr, nullptr);
  std::string result(size, 0);
  WideCharToMultiByte(CP_UTF8, 0, value.data(), static_cast<int>(value.size()), result.data(), size, nullptr, nullptr);
  return result;
}

std::string HStringToUtf8(const winrt::hstring& value) {
  return WideToUtf8(std::wstring(value.c_str(), value.size()));
}

std::wstring ReadWindowTitle(HWND hwnd) {
  const int length = GetWindowTextLengthW(hwnd);
  if (length <= 0) return L"";
  std::wstring title(length + 1, L'\0');
  const int copied = GetWindowTextW(hwnd, title.data(), length + 1);
  title.resize(std::max(copied, 0));
  return title;
}

std::wstring ReadProcessName(DWORD pid) {
  HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
  if (process == nullptr) return L"Unknown";
  wchar_t path[MAX_PATH] = {};
  DWORD size = MAX_PATH;
  std::wstring name = L"Unknown";
  if (QueryFullProcessImageNameW(process, 0, path, &size)) {
    name.assign(path, size);
    const size_t slash = name.find_last_of(L"\\/");
    if (slash != std::wstring::npos) name = name.substr(slash + 1);
  }
  CloseHandle(process);
  return name;
}

void SendVirtualKey(WORD virtual_key) {
  INPUT inputs[2] = {};
  inputs[0].type = INPUT_KEYBOARD;
  inputs[0].ki.wVk = virtual_key;
  inputs[1].type = INPUT_KEYBOARD;
  inputs[1].ki.wVk = virtual_key;
  inputs[1].ki.dwFlags = KEYEVENTF_KEYUP;
  SendInput(2, inputs, sizeof(INPUT));
}

IAudioEndpointVolume* CreateEndpointVolume() {
  IMMDeviceEnumerator* enumerator = nullptr;
  IMMDevice* device = nullptr;
  IAudioEndpointVolume* volume = nullptr;
  HRESULT result = CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL, __uuidof(IMMDeviceEnumerator), reinterpret_cast<void**>(&enumerator));
  if (FAILED(result) || enumerator == nullptr) return nullptr;
  result = enumerator->GetDefaultAudioEndpoint(eRender, eConsole, &device);
  enumerator->Release();
  if (FAILED(result) || device == nullptr) return nullptr;
  result = device->Activate(__uuidof(IAudioEndpointVolume), CLSCTX_ALL, nullptr, reinterpret_cast<void**>(&volume));
  device->Release();
  if (FAILED(result)) return nullptr;
  return volume;
}

double ReadDoubleArgument(const EncodableValue* arguments, const std::string& key, double fallback) {
  if (arguments == nullptr) return fallback;
  const auto* map = std::get_if<EncodableMap>(arguments);
  if (map == nullptr) return fallback;
  const auto iterator = map->find(EncodableValue(key));
  if (iterator == map->end()) return fallback;
  if (const auto* value = std::get_if<double>(&iterator->second)) return *value;
  if (const auto* value = std::get_if<int32_t>(&iterator->second)) return static_cast<double>(*value);
  if (const auto* value = std::get_if<int64_t>(&iterator->second)) return static_cast<double>(*value);
  return fallback;
}

bool ReadBoolArgument(const EncodableValue* arguments, const std::string& key, bool fallback) {
  if (arguments == nullptr) return fallback;
  const auto* map = std::get_if<EncodableMap>(arguments);
  if (map == nullptr) return fallback;
  const auto iterator = map->find(EncodableValue(key));
  if (iterator == map->end()) return fallback;
  if (const auto* value = std::get_if<bool>(&iterator->second)) return *value;
  return fallback;
}

std::string ReadStringArgument(const EncodableValue* arguments, const std::string& key, const std::string& fallback) {
  if (arguments == nullptr) return fallback;
  const auto* map = std::get_if<EncodableMap>(arguments);
  if (map == nullptr) return fallback;
  const auto iterator = map->find(EncodableValue(key));
  if (iterator == map->end()) return fallback;
  if (const auto* value = std::get_if<std::string>(&iterator->second)) return *value;
  return fallback;
}

std::wstring Utf8ToWide(const std::string& value) {
  if (value.empty()) return L"";
  const int size = MultiByteToWideChar(CP_UTF8, 0, value.data(), static_cast<int>(value.size()), nullptr, 0);
  std::wstring result(size, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, value.data(), static_cast<int>(value.size()), result.data(), size);
  return result;
}

std::wstring CurrentExecutablePath() {
  std::wstring path(MAX_PATH, L'\0');
  DWORD copied = GetModuleFileNameW(nullptr, path.data(), static_cast<DWORD>(path.size()));
  while (copied == path.size()) {
    path.resize(path.size() * 2, L'\0');
    copied = GetModuleFileNameW(nullptr, path.data(), static_cast<DWORD>(path.size()));
  }
  path.resize(copied);
  return path;
}

std::string GetLocalIPAddress() {
  char hostname[256];
  if (gethostname(hostname, sizeof(hostname)) != 0) return "";

  struct addrinfo hints = {};
  hints.ai_family = AF_INET;
  hints.ai_socktype = SOCK_STREAM;

  struct addrinfo* res = nullptr;
  if (getaddrinfo(hostname, nullptr, &hints, &res) != 0) return "";

  struct sockaddr_in* addr = reinterpret_cast<struct sockaddr_in*>(res->ai_addr);
  std::string ip = WideToUtf8(InetNtopA(AF_INET, &addr->sin_addr, nullptr, 0)); // This is simplified

  // More robust way to get the IP
  char ipStr[INET_ADDRSTRLEN];
  inet_ntop(AF_INET, &addr->sin_addr, ipStr, INET_ADDRSTRLEN);

  freeaddrinfo(res);
  return std::string(ipStr);
}

bool SetAutoStartEnabled(bool enabled) {
  HKEY run_key = nullptr;
  LONG result = RegCreateKeyExW(HKEY_CURRENT_USER, kRunKeyPath, 0, nullptr, 0, KEY_SET_VALUE, nullptr, &run_key, nullptr);
  if (result != ERROR_SUCCESS || run_key == nullptr) return false;
  if (enabled) {
    const std::wstring command = L"\"" + CurrentExecutablePath() + L"\"";
    result = RegSetValueExW(run_key, kAutoStartValueName, 0, REG_SZ, reinterpret_cast<const BYTE*>(command.c_str()), static_cast<DWORD>((command.size() + 1) * sizeof(wchar_t)));
  } else {
    result = RegDeleteValueW(run_key, kAutoStartValueName);
    if (result == ERROR_FILE_NOT_FOUND) result = ERROR_SUCCESS;
  }
  RegCloseKey(run_key);
  return result == ERROR_SUCCESS;
}

bool IsAutoStartEnabled() {
  HKEY run_key = nullptr;
  LONG result = RegOpenKeyExW(HKEY_CURRENT_USER, kRunKeyPath, 0, KEY_QUERY_VALUE, &run_key);
  if (result != ERROR_SUCCESS || run_key == nullptr) return false;
  result = RegQueryValueExW(run_key, kAutoStartValueName, nullptr, nullptr, nullptr, nullptr);
  RegCloseKey(run_key);
  return result == ERROR_SUCCESS;
}

bool ShowSystemNotification(const std::string& title, const std::string& body) {
  NOTIFYICONDATAW data = {};
  data.cbSize = sizeof(NOTIFYICONDATAW);
  data.hWnd = NotificationHostWindow();
  if (data.hWnd == nullptr) return false;
  data.uID = 1208;
  data.uFlags = NIF_INFO | NIF_ICON | NIF_TIP;
  data.hIcon = LoadIcon(nullptr, IDI_APPLICATION);
  const std::wstring wide_title = Utf8ToWide(title);
  const std::wstring wide_body = Utf8ToWide(body);
  const std::wstring tip = L"Connector";
  wcsncpy_s(data.szTip, tip.c_str(), _TRUNCATE);
  wcsncpy_s(data.szInfoTitle, wide_title.c_str(), _TRUNCATE);
  wcsncpy_s(data.szInfo, wide_body.c_str(), _TRUNCATE);
  data.dwInfoFlags = NIIF_INFO;
  Shell_NotifyIconW(NIM_ADD, &data);
  const BOOL shown = Shell_NotifyIconW(NIM_MODIFY, &data);
  return shown == TRUE;
}

int64_t TimeSpanToMs(winrt::Windows::Foundation::TimeSpan value) {
  return std::chrono::duration_cast<std::chrono::milliseconds>(value).count();
}

int64_t ClampTimelineMs(int64_t value, int64_t max_value) {
  return std::clamp<int64_t>(value, 0, std::max<int64_t>(0, max_value));
}

int64_t TimelineAgeMs(winrt::Windows::Foundation::DateTime last_updated_time) {
  const auto now = winrt::clock::now();
  if (last_updated_time > now) return 0;
  return std::chrono::duration_cast<std::chrono::milliseconds>(now - last_updated_time).count();
}

EncodableMap ReadMediaStatusOnWorker() {
  EncodableMap status;
  try {
    winrt::init_apartment(winrt::apartment_type::multi_threaded);
    auto manager = media_control::GlobalSystemMediaTransportControlsSessionManager::RequestAsync().get();
    auto session = manager.GetCurrentSession();
    if (!session) return status;
    auto media_properties = session.TryGetMediaPropertiesAsync().get();
    auto timeline = session.GetTimelineProperties();
    auto playback_info = session.GetPlaybackInfo();
    const int64_t start_ms = TimeSpanToMs(timeline.StartTime());
    const int64_t end_ms = TimeSpanToMs(timeline.EndTime());
    const int64_t duration_ms = std::max<int64_t>(0, end_ms - start_ms);
    const bool is_playing = playback_info.PlaybackStatus() == media_control::GlobalSystemMediaTransportControlsSessionPlaybackStatus::Playing;
    const int64_t timeline_age_ms = is_playing ? TimelineAgeMs(timeline.LastUpdatedTime()) : 0;
    const int64_t position_ms = ClampTimelineMs(TimeSpanToMs(timeline.Position()) - start_ms + timeline_age_ms, duration_ms);
    status[EncodableValue("title")] = EncodableValue(HStringToUtf8(media_properties.Title()));
    status[EncodableValue("artist")] = EncodableValue(HStringToUtf8(media_properties.Artist()));
    status[EncodableValue("album")] = EncodableValue(HStringToUtf8(media_properties.AlbumTitle()));
    status[EncodableValue("sourceApp")] = EncodableValue(HStringToUtf8(session.SourceAppUserModelId()));
    status[EncodableValue("isPlaying")] = EncodableValue(is_playing);
    status[EncodableValue("positionMs")] = EncodableValue(position_ms);
    status[EncodableValue("durationMs")] = EncodableValue(duration_ms);
  } catch (const winrt::hresult_error&) {
    return EncodableMap();
  }
  return status;
}

EncodableMap ReadMediaStatus() {
  return std::async(std::launch::async, []() {
    return ReadMediaStatusOnWorker();
  }).get();
}

bool SeekCurrentMediaOnWorker(

