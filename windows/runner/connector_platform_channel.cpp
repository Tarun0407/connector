#define WIN32_LEAN_AND_MEAN
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <shellapi.h>
#include <endpointvolume.h>
#include <mmdeviceapi.h>
#include <iostream>
#include <string>
#include <vector>
#include <thread>
#include <mutex>
#include <cstdio>
#include <variant>
#include <algorithm>
#include <chrono>
#include <future>
#include <memory>

#include "connector_platform_channel.h"
#include "resource.h"

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Media.Control.h>
#include <winrt/Windows.Devices.Enumeration.h>

#pragma comment(lib, "ws2_32.lib")
#pragma comment(lib, "shell32.lib")

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
constexpr wchar_t kNotificationWindowClass[] = L"ConnectorNotificationWindow";
constexpr int kLocalPort = 5005;
constexpr UINT kTrayIconId = 1208;
constexpr UINT WM_APP_TRAY = WM_APP + 1;

} // namespace

HWND g_main_hwnd = nullptr;
bool g_trayIconCreated = false;

namespace {

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

std::wstring Utf8ToWide(const std::string& value) {
    if (value.empty()) return L"";
    const int size = MultiByteToWideChar(CP_UTF8, 0, value.data(), static_cast<int>(value.size()), nullptr, 0);
    std::wstring result(size, L'\0');
    MultiByteToWideChar(CP_UTF8, 0, value.data(), static_cast<int>(value.size()), result.data(), size);
    return result;
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
        if (slash != std::wstring::npos) {
            name = name.substr(slash + 1);
        }
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

    HRESULT result = CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr,
                                      CLSCTX_ALL, __uuidof(IMMDeviceEnumerator),
                                      reinterpret_cast<void**>(&enumerator));
    if (FAILED(result) || enumerator == nullptr) return nullptr;

    result = enumerator->GetDefaultAudioEndpoint(eRender, eConsole, &device);
    enumerator->Release();
    if (FAILED(result) || device == nullptr) return nullptr;

    result = device->Activate(__uuidof(IAudioEndpointVolume), CLSCTX_ALL,
                              nullptr, reinterpret_cast<void**>(&volume));
    device->Release();
    if (FAILED(result)) return nullptr;
    return volume;
}

void SendOk(SOCKET clientSocket) {
    send(clientSocket, "ok\n", 3, 0);
}

std::wstring GetDownloadsPath() {
    wchar_t* userProfile = nullptr;
    size_t len = 0;
    if (_wdupenv_s(&userProfile, &len, L"USERPROFILE") == 0 && userProfile != nullptr) {
        std::wstring path = std::wstring(userProfile) + L"\\Downloads\\Connector";
        free(userProfile);
        return path;
    }
    return L"C:\\Users\\Public\\Downloads\\Connector";
}

std::string ReadLine(SOCKET sock) {
    std::string line;
    char c;
    while (recv(sock, &c, 1, 0) == 1) {
        if (c == '\n') break;
        if (c != '\r') line += c;
    }
    return line;
}

void HandleLocalClient(SOCKET clientSocket) {
    std::string command = ReadLine(clientSocket);
    if (command.empty()) { closesocket(clientSocket); return; }

    if (command == "sendFile") {
        std::string header = ReadLine(clientSocket);
        if (header.empty()) { closesocket(clientSocket); return; }
        size_t delimiterPos = header.find('|');
        if (delimiterPos == std::string::npos) { closesocket(clientSocket); return; }
        std::string fileName = header.substr(0, delimiterPos);
        long long fileSize = std::stoll(header.substr(delimiterPos + 1));
        std::wstring downloadsPath = GetDownloadsPath();
        std::wstring fullPath = downloadsPath + L"\\" + Utf8ToWide(fileName);
        CreateDirectoryW(downloadsPath.c_str(), nullptr);
        FILE* file = nullptr;
        _wfopen_s(&file, fullPath.c_str(), L"wb");
        if (!file) { closesocket(clientSocket); return; }
        char buffer[4096];
        long long totalReceived = 0;
        while (totalReceived < fileSize) {
            int toRead = static_cast<int>((sizeof(buffer) < static_cast<size_t>(fileSize - totalReceived)) ? sizeof(buffer) : static_cast<size_t>(fileSize - totalReceived));
            int read = recv(clientSocket, buffer, toRead, 0);
            if (read <= 0) break;
            totalReceived += read;
            fwrite(buffer, 1, read, file);
        }
        fclose(file);
        SendOk(clientSocket);
    } else {
        if (command == "volumeUp") { SendVirtualKey(VK_VOLUME_UP); SendOk(clientSocket); }
        else if (command == "volumeDown") { SendVirtualKey(VK_VOLUME_DOWN); SendOk(clientSocket); }
        else if (command == "volumeMute") { SendVirtualKey(VK_VOLUME_MUTE); SendOk(clientSocket); }
        else if (command == "mediaPlayPause") { SendVirtualKey(VK_MEDIA_PLAY_PAUSE); SendOk(clientSocket); }
        else if (command == "mediaNext") { SendVirtualKey(VK_MEDIA_NEXT_TRACK); SendOk(clientSocket); }
        else if (command == "mediaPrevious") { SendVirtualKey(VK_MEDIA_PREV_TRACK); SendOk(clientSocket); }
        else if (command == "lock") { LockWorkStation(); SendOk(clientSocket); }
    }
    closesocket(clientSocket);
}

void StartLocalServer() {
    std::thread([]() {
        WSADATA wsaData;
        if (WSAStartup(MAKEWORD(2, 2), &wsaData) != 0) return;
        SOCKET listenSocket = socket(AF_INET, SOCK_STREAM, 0);
        if (listenSocket == INVALID_SOCKET) return;
        int reuse = 1;
        setsockopt(listenSocket, SOL_SOCKET, SO_REUSEADDR, reinterpret_cast<const char*>(&reuse), sizeof(reuse));
        sockaddr_in serverAddr = {};
        serverAddr.sin_family = AF_INET;
        serverAddr.sin_addr.s_addr = INADDR_ANY;
        serverAddr.sin_port = htons(kLocalPort);
        if (bind(listenSocket, (struct sockaddr*)&serverAddr, sizeof(serverAddr)) == SOCKET_ERROR) {
            closesocket(listenSocket); return;
        }
        listen(listenSocket, SOMAXCONN);
        while (true) {
            SOCKET clientSocket = accept(listenSocket, nullptr, nullptr);
            if (clientSocket != INVALID_SOCKET) std::thread(HandleLocalClient, clientSocket).detach();
        }
        closesocket(listenSocket);
        WSACleanup();
    }).detach();
}

void RemoveSystemTrayIcon();

LRESULT CALLBACK NotificationWindowProc(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) {
    if (message == WM_APP_TRAY) {
        switch (lparam) {
            case WM_RBUTTONUP:
            case WM_CONTEXTMENU: {
                HMENU menu = CreatePopupMenu();
                AppendMenuW(menu, MF_STRING, 1, L"Show Connector");
                AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
                AppendMenuW(menu, MF_STRING, 2, L"Exit");
                POINT pt;
                GetCursorPos(&pt);
                SetForegroundWindow(hwnd);
                const int cmd = TrackPopupMenu(menu, TPM_RETURNCMD | TPM_RIGHTBUTTON, pt.x, pt.y, 0, hwnd, nullptr);
                PostMessage(hwnd, WM_NULL, 0, 0);
                DestroyMenu(menu);
                if (cmd == 1) {
                    if (g_main_hwnd && IsWindow(g_main_hwnd)) {
                        ShowWindow(g_main_hwnd, SW_SHOW);
                        SetForegroundWindow(g_main_hwnd);
                    }
                } else if (cmd == 2) {
                    RemoveSystemTrayIcon();
                    PostQuitMessage(0);
                }
                return 0;
            }
            case WM_LBUTTONDBLCLK: {
                if (g_main_hwnd && IsWindow(g_main_hwnd)) {
                    ShowWindow(g_main_hwnd, SW_SHOW);
                    SetForegroundWindow(g_main_hwnd);
                }
                return 0;
            }
        }
    }
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

void CreateSystemTrayIcon() {
    if (g_trayIconCreated) return;
    HWND hwnd = NotificationHostWindow();
    if (!hwnd) return;
    NOTIFYICONDATAW nid = {};
    nid.cbSize = sizeof(NOTIFYICONDATAW);
    nid.hWnd = hwnd;
    nid.uID = kTrayIconId;
    nid.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
    nid.uCallbackMessage = WM_APP_TRAY;
    nid.hIcon = LoadIcon(GetModuleHandle(nullptr), MAKEINTRESOURCE(IDI_APP_ICON));
    wcsncpy_s(nid.szTip, L"Connector", _TRUNCATE);
    g_trayIconCreated = Shell_NotifyIconW(NIM_ADD, &nid) == TRUE;
}

void RemoveSystemTrayIcon() {
    if (!g_trayIconCreated) return;
    NOTIFYICONDATAW nid = {};
    nid.cbSize = sizeof(NOTIFYICONDATAW);
    nid.hWnd = NotificationHostWindow();
    nid.uID = kTrayIconId;
    Shell_NotifyIconW(NIM_DELETE, &nid);
    g_trayIconCreated = false;
}

bool ShowSystemNotification(const std::string& title, const std::string& body) {
    CreateSystemTrayIcon();
    HWND hwnd = NotificationHostWindow();
    if (hwnd == nullptr) return false;
    NOTIFYICONDATAW data = {};
    data.cbSize = sizeof(NOTIFYICONDATAW);
    data.hWnd = hwnd;
    data.uID = kTrayIconId;
    data.uFlags = NIF_INFO;
    std::wstring wide_title = Utf8ToWide(title);
    std::wstring wide_body = Utf8ToWide(body);
    wcsncpy_s(data.szInfoTitle, wide_title.c_str(), _TRUNCATE);
    wcsncpy_s(data.szInfo, wide_body.c_str(), _TRUNCATE);
    data.dwInfoFlags = NIIF_INFO;
    data.uTimeout = 5000;
    return Shell_NotifyIconW(NIM_MODIFY, &data) == TRUE;
}

int64_t TimeSpanToMs(winrt::Windows::Foundation::TimeSpan value) {
    return std::chrono::duration_cast<std::chrono::milliseconds>(value).count();
}

EncodableMap ReadMediaStatusOnWorker() {
    EncodableMap status;
    try {
        winrt::init_apartment();
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
        status[EncodableValue("title")] = EncodableValue(HStringToUtf8(media_properties.Title()));
        status[EncodableValue("artist")] = EncodableValue(HStringToUtf8(media_properties.Artist()));
        status[EncodableValue("album")] = EncodableValue(HStringToUtf8(media_properties.AlbumTitle()));
        status[EncodableValue("isPlaying")] = EncodableValue(is_playing);
        status[EncodableValue("positionMs")] = EncodableValue(TimeSpanToMs(timeline.Position()) - start_ms);
        status[EncodableValue("durationMs")] = EncodableValue(duration_ms);
    } catch (...) {}
    return status;
}

EncodableMap ReadMediaStatus() {
    return std::async(std::launch::async, []() { return ReadMediaStatusOnWorker(); }).get();
}

std::wstring CurrentExecutablePath() {
    std::wstring path(MAX_PATH, L'\0');
    DWORD copied = GetModuleFileNameW(nullptr, path.data(), static_cast<DWORD>(path.size()));
    path.resize(copied);
    return path;
}

bool SetAutoStartEnabled(bool enabled) {
    HKEY run_key = nullptr;
    if (RegCreateKeyExW(HKEY_CURRENT_USER, kRunKeyPath, 0, nullptr, 0, KEY_SET_VALUE, nullptr, &run_key, nullptr) != ERROR_SUCCESS) return false;
    if (enabled) {
        std::wstring cmd = L"\"" + CurrentExecutablePath() + L"\"";
        RegSetValueExW(run_key, kAutoStartValueName, 0, REG_SZ, reinterpret_cast<const BYTE*>(cmd.c_str()), static_cast<DWORD>((cmd.size() + 1) * sizeof(wchar_t)));
    } else {
        RegDeleteValueW(run_key, kAutoStartValueName);
    }
    RegCloseKey(run_key);
    return true;
}

bool IsAutoStartEnabled() {
    HKEY run_key = nullptr;
    if (RegOpenKeyExW(HKEY_CURRENT_USER, kRunKeyPath, 0, KEY_QUERY_VALUE, &run_key) != ERROR_SUCCESS) return false;
    bool enabled = RegQueryValueExW(run_key, kAutoStartValueName, nullptr, nullptr, nullptr, nullptr) == ERROR_SUCCESS;
    RegCloseKey(run_key);
    return enabled;
}

double ReadDoubleArgument(const EncodableValue* args, const std::string& key, double fallback) {
    if (!args) return fallback;
    if (const auto* map = std::get_if<EncodableMap>(args)) {
        auto it = map->find(EncodableValue(key));
        if (it != map->end()) {
            if (const auto* v = std::get_if<double>(&it->second)) return *v;
            if (const auto* v = std::get_if<int32_t>(&it->second)) return static_cast<double>(*v);
            if (const auto* v = std::get_if<int64_t>(&it->second)) return static_cast<double>(*v);
        }
    }
    return fallback;
}

bool ReadBoolArgument(const EncodableValue* args, const std::string& key, bool fallback) {
    if (!args) return fallback;
    if (const auto* map = std::get_if<EncodableMap>(args)) {
        auto it = map->find(EncodableValue(key));
        if (it != map->end()) {
            if (const auto* v = std::get_if<bool>(&it->second)) return *v;
        }
    }
    return fallback;
}

std::string ReadStringArgument(const EncodableValue* args, const std::string& key, const std::string& fallback) {
    if (!args) return fallback;
    if (const auto* map = std::get_if<EncodableMap>(args)) {
        auto it = map->find(EncodableValue(key));
        if (it != map->end()) {
            if (const auto* v = std::get_if<std::string>(&it->second)) return *v;
        }
    }
    return fallback;
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
    char ipStr[INET_ADDRSTRLEN];
    inet_ntop(AF_INET, &addr->sin_addr, ipStr, INET_ADDRSTRLEN);
    freeaddrinfo(res);
    return std::string(ipStr);
}

void HandleMethodCall(
    const MethodCall<EncodableValue>& call,
    std::unique_ptr<MethodResult<EncodableValue>> result) {
    const std::string& method = call.method_name();

    if (method == "getLocalIp") {
        result->Success(EncodableValue(GetLocalIPAddress()));
        return;
    }
    if (method == "setAutoStart") {
        bool enabled = ReadBoolArgument(call.arguments(), "enabled", false);
        result->Success(EncodableValue(SetAutoStartEnabled(enabled)));
        return;
    }
    if (method == "isAutoStartEnabled") {
        result->Success(EncodableValue(IsAutoStartEnabled()));
        return;
    }
    if (method == "openAutoStartSettings") {
        result->Success(EncodableValue(false));
        return;
    }
    if (method == "volumeUp") {
        SendVirtualKey(VK_VOLUME_UP);
        result->Success(EncodableValue(true));
        return;
    }
    if (method == "volumeDown") {
        SendVirtualKey(VK_VOLUME_DOWN);
        result->Success(EncodableValue(true));
        return;
    }
    if (method == "volumeMute") {
        SendVirtualKey(VK_VOLUME_MUTE);
        result->Success(EncodableValue(true));
        return;
    }
    if (method == "mediaPlayPause") {
        SendVirtualKey(VK_MEDIA_PLAY_PAUSE);
        result->Success(EncodableValue(true));
        return;
    }
    if (method == "mediaNext") {
        SendVirtualKey(VK_MEDIA_NEXT_TRACK);
        result->Success(EncodableValue(true));
        return;
    }
    if (method == "mediaPrevious") {
        SendVirtualKey(VK_MEDIA_PREV_TRACK);
        result->Success(EncodableValue(true));
        return;
    }
    if (method == "mediaSeek") {
        result->Success(EncodableValue(false));
        return;
    }
    if (method == "lockComputer") {
        result->Success(EncodableValue(LockWorkStation() == TRUE));
        return;
    }
    if (method == "showSystemNotification") {
        std::string title = ReadStringArgument(call.arguments(), "title", "Connector");
        std::string body = ReadStringArgument(call.arguments(), "body", "");
        result->Success(EncodableValue(ShowSystemNotification(title, body)));
        return;
    }
    if (method == "getMediaStatus") {
        result->Success(EncodableValue(ReadMediaStatus()));
        return;
    }
    if (method == "getVolume") {
        IAudioEndpointVolume* vol = CreateEndpointVolume();
        if (!vol) {
            result->Success(EncodableValue());
            return;
        }
        float level = 0;
        const HRESULT hr = vol->GetMasterVolumeLevelScalar(&level);
        vol->Release();
        if (FAILED(hr)) {
            result->Success(EncodableValue());
            return;
        }
        result->Success(EncodableValue(static_cast<double>(level * 100.0)));
        return;
    }
    if (method == "setVolume") {
        double level = ReadDoubleArgument(call.arguments(), "level", 50.0);
        IAudioEndpointVolume* vol = CreateEndpointVolume();
        if (!vol) {
            result->Success(EncodableValue(false));
            return;
        }
        const HRESULT hr = vol->SetMasterVolumeLevelScalar(static_cast<float>(level / 100.0), nullptr);
        vol->Release();
        result->Success(EncodableValue(SUCCEEDED(hr)));
        return;
    }
    if (method == "isMuted") {
        IAudioEndpointVolume* vol = CreateEndpointVolume();
        if (!vol) {
            result->Success(EncodableValue());
            return;
        }
        BOOL muted = FALSE;
        const HRESULT hr = vol->GetMute(&muted);
        vol->Release();
        if (FAILED(hr)) {
            result->Success(EncodableValue());
            return;
        }
        result->Success(EncodableValue(muted == TRUE));
        return;
    }
    if (method == "listWindows") {
        EncodableList windows;
        EnumWindows([](HWND hwnd, LPARAM lParam) -> BOOL {
            if (!IsWindowVisible(hwnd) || hwnd == GetShellWindow()) return TRUE;
            auto* list = reinterpret_cast<EncodableList*>(lParam);
            std::wstring title = ReadWindowTitle(hwnd);
            if (title.empty()) return TRUE;
            DWORD pid = 0;
            GetWindowThreadProcessId(hwnd, &pid);
            std::wstring process = ReadProcessName(pid);
            EncodableMap win;
            win[EncodableValue("id")] = EncodableValue(WideToUtf8(process) + "::" + WideToUtf8(title));
            win[EncodableValue("title")] = EncodableValue(WideToUtf8(title));
            win[EncodableValue("process")] = EncodableValue(WideToUtf8(process));
            win[EncodableValue("pid")] = EncodableValue(static_cast<int32_t>(pid));
            list->push_back(EncodableValue(win));
            return TRUE;
        }, reinterpret_cast<LPARAM>(&windows));
        result->Success(EncodableValue(windows));
        return;
    }
    if (method == "minimizeToTray") {
        if (g_main_hwnd && IsWindow(g_main_hwnd)) {
            ShowWindow(g_main_hwnd, SW_HIDE);
        }
        result->Success(EncodableValue(true));
        return;
    }
    if (method == "exitApp") {
        RemoveSystemTrayIcon();
        PostQuitMessage(0);
        result->Success(EncodableValue(true));
        return;
    }
    if (method == "openFile") {
        std::string path = ReadStringArgument(call.arguments(), "path", "");
        if (!path.empty()) {
            ShellExecuteW(nullptr, L"open", Utf8ToWide(path).c_str(), nullptr, nullptr, SW_SHOWNORMAL);
        }
        result->Success(EncodableValue(true));
        return;
    }

    result->NotImplemented();
}

} // namespace

void SetMainWindowHandle(HWND hwnd) {
    g_main_hwnd = hwnd;
    CreateSystemTrayIcon();
}

void RegisterConnectorPlatformChannel(flutter::FlutterEngine* engine) {
    static std::unique_ptr<MethodChannel<EncodableValue>> channel;
    static bool local_server_started = false;
    if (!local_server_started) {
        StartLocalServer();
        local_server_started = true;
    }

    channel = std::make_unique<MethodChannel<EncodableValue>>(
        engine->messenger(), kChannelName, &StandardMethodCodec::GetInstance());
    channel->SetMethodCallHandler(HandleMethodCall);
}
