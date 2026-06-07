#include "connector_platform_channel.h"

#include <endpointvolume.h>
#include <dpapi.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <mmdeviceapi.h>
#include <shellapi.h>
#include <windows.h>
#include <wtsapi32.h>
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
constexpr wchar_t kRunKeyPath[] =
    L"Software\\Microsoft\\Windows\\CurrentVersion\\Run";
constexpr wchar_t kAutoStartValueName[] = L"Connector";
constexpr wchar_t kConnectorRegistryPath[] = L"Software\\Connector";
constexpr wchar_t kRemoteUnlockSecretValueName[] = L"RemoteUnlockSecret";
constexpr wchar_t kNotificationWindowClass[] = L"ConnectorNotificationWindow";

LRESULT CALLBACK NotificationWindowProc(HWND hwnd, UINT message,
                                         WPARAM wparam, LPARAM lparam) {
  return DefWindowProc(hwnd, message, wparam, lparam);
}

HWND NotificationHostWindow() {
  static HWND hwnd = nullptr;
  if (hwnd != nullptr) {
    return hwnd;
  }

  WNDCLASSW window_class = {};
  window_class.lpfnWndProc = NotificationWindowProc;
  window_class.hInstance = GetModuleHandle(nullptr);
  window_class.lpszClassName = kNotificationWindowClass;
  RegisterClassW(&window_class);

  hwnd = CreateWindowExW(0, kNotificationWindowClass, L"Connector", 0, 0, 0, 0,
                         0, HWND_MESSAGE, nullptr, GetModuleHandle(nullptr),
                         nullptr);
  return hwnd;
}

std::string WideToUtf8(const std::wstring& value) {
  if (value.empty()) {
    return "";
  }

  const int size = WideCharToMultiByte(CP_UTF8, 0, value.data(),
                                       static_cast<int>(value.size()), nullptr,
                                       0, nullptr, nullptr);
  std::string result(size, 0);
  WideCharToMultiByte(CP_UTF8, 0, value.data(), static_cast<int>(value.size()),
                      result.data(), size, nullptr, nullptr);
  return result;
}

std::string HStringToUtf8(const winrt::hstring& value) {
  return WideToUtf8(std::wstring(value.c_str(), value.size()));
}

std::wstring ReadWindowTitle(HWND hwnd) {
  const int length = GetWindowTextLengthW(hwnd);
  if (length <= 0) {
    return L"";
  }

  std::wstring title(length + 1, L'\0');
  const int copied = GetWindowTextW(hwnd, title.data(), length + 1);
  title.resize(std::max(copied, 0));
  return title;
}

std::wstring ReadProcessName(DWORD pid) {
  HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
  if (process == nullptr) {
    return L"Unknown";
  }

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
                                    CLSCTX_ALL,
                                    __uuidof(IMMDeviceEnumerator),
                                    reinterpret_cast<void**>(&enumerator));
  if (FAILED(result) || enumerator == nullptr) {
    return nullptr;
  }

  result = enumerator->GetDefaultAudioEndpoint(eRender, eConsole, &device);
  enumerator->Release();
  if (FAILED(result) || device == nullptr) {
    return nullptr;
  }

  result = device->Activate(__uuidof(IAudioEndpointVolume), CLSCTX_ALL, nullptr,
                            reinterpret_cast<void**>(&volume));
  device->Release();
  if (FAILED(result)) {
    return nullptr;
  }

  return volume;
}

double ReadDoubleArgument(const EncodableValue* arguments,
                          const std::string& key,
                          double fallback) {
  if (arguments == nullptr) {
    return fallback;
  }

  const auto* map = std::get_if<EncodableMap>(arguments);
  if (map == nullptr) {
    return fallback;
  }

  const auto iterator = map->find(EncodableValue(key));
  if (iterator == map->end()) {
    return fallback;
  }

  if (const auto* value = std::get_if<double>(&iterator->second)) {
    return *value;
  }
  if (const auto* value = std::get_if<int32_t>(&iterator->second)) {
    return static_cast<double>(*value);
  }
  if (const auto* value = std::get_if<int64_t>(&iterator->second)) {
    return static_cast<double>(*value);
  }
  return fallback;
}

bool ReadBoolArgument(const EncodableValue* arguments,
                      const std::string& key,
                      bool fallback) {
  if (arguments == nullptr) {
    return fallback;
  }

  const auto* map = std::get_if<EncodableMap>(arguments);
  if (map == nullptr) {
    return fallback;
  }

  const auto iterator = map->find(EncodableValue(key));
  if (iterator == map->end()) {
    return fallback;
  }

  if (const auto* value = std::get_if<bool>(&iterator->second)) {
    return *value;
  }
  return fallback;
}

std::string ReadStringArgument(const EncodableValue* arguments,
                               const std::string& key,
                               const std::string& fallback) {
  if (arguments == nullptr) {
    return fallback;
  }

  const auto* map = std::get_if<EncodableMap>(arguments);
  if (map == nullptr) {
    return fallback;
  }

  const auto iterator = map->find(EncodableValue(key));
  if (iterator == map->end()) {
    return fallback;
  }

  if (const auto* value = std::get_if<std::string>(&iterator->second)) {
    return *value;
  }
  return fallback;
}

std::wstring Utf8ToWide(const std::string& value) {
  if (value.empty()) {
    return L"";
  }
  const int size = MultiByteToWideChar(CP_UTF8, 0, value.data(),
                                       static_cast<int>(value.size()), nullptr,
                                       0);
  std::wstring result(size, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, value.data(), static_cast<int>(value.size()),
                      result.data(), size);
  return result;
}

std::wstring CurrentExecutablePath() {
  std::wstring path(MAX_PATH, L'\0');
  DWORD copied = GetModuleFileNameW(nullptr, path.data(),
                                    static_cast<DWORD>(path.size()));
  while (copied == path.size()) {
    path.resize(path.size() * 2, L'\0');
    copied = GetModuleFileNameW(nullptr, path.data(),
                                static_cast<DWORD>(path.size()));
  }
  path.resize(copied);
  return path;
}

bool SetAutoStartEnabled(bool enabled) {
  HKEY run_key = nullptr;
  LONG result = RegCreateKeyExW(HKEY_CURRENT_USER, kRunKeyPath, 0, nullptr, 0,
                                KEY_SET_VALUE, nullptr, &run_key, nullptr);
  if (result != ERROR_SUCCESS || run_key == nullptr) {
    return false;
  }

  if (enabled) {
    const std::wstring command = L"\"" + CurrentExecutablePath() + L"\"";
    result = RegSetValueExW(
        run_key, kAutoStartValueName, 0, REG_SZ,
        reinterpret_cast<const BYTE*>(command.c_str()),
        static_cast<DWORD>((command.size() + 1) * sizeof(wchar_t)));
  } else {
    result = RegDeleteValueW(run_key, kAutoStartValueName);
    if (result == ERROR_FILE_NOT_FOUND) {
      result = ERROR_SUCCESS;
    }
  }

  RegCloseKey(run_key);
  return result == ERROR_SUCCESS;
}

bool IsAutoStartEnabled() {
  HKEY run_key = nullptr;
  LONG result = RegOpenKeyExW(HKEY_CURRENT_USER, kRunKeyPath, 0, KEY_QUERY_VALUE,
                              &run_key);
  if (result != ERROR_SUCCESS || run_key == nullptr) {
    return false;
  }

  result = RegQueryValueExW(run_key, kAutoStartValueName, nullptr, nullptr,
                            nullptr, nullptr);
  RegCloseKey(run_key);
  return result == ERROR_SUCCESS;
}

bool SaveProtectedUnlockPassword(const std::string& password_utf8) {
  std::wstring password = Utf8ToWide(password_utf8);
  if (password.empty()) {
    return false;
  }

  DATA_BLOB plain = {};
  plain.cbData =
      static_cast<DWORD>((password.size() + 1) * sizeof(wchar_t));
  plain.pbData = reinterpret_cast<BYTE*>(password.data());

  DATA_BLOB protected_data = {};
  const BOOL protected_ok = CryptProtectData(
      &plain, L"Connector remote unlock password", nullptr, nullptr, nullptr,
      CRYPTPROTECT_UI_FORBIDDEN, &protected_data);
  SecureZeroMemory(password.data(), password.size() * sizeof(wchar_t));
  if (protected_ok != TRUE) {
    return false;
  }

  HKEY connector_key = nullptr;
  LONG result =
      RegCreateKeyExW(HKEY_CURRENT_USER, kConnectorRegistryPath, 0, nullptr, 0,
                      KEY_SET_VALUE, nullptr, &connector_key, nullptr);
  if (result == ERROR_SUCCESS && connector_key != nullptr) {
    result = RegSetValueExW(connector_key, kRemoteUnlockSecretValueName, 0,
                            REG_BINARY, protected_data.pbData,
                            protected_data.cbData);
  }

  if (connector_key != nullptr) {
    RegCloseKey(connector_key);
  }
  SecureZeroMemory(protected_data.pbData, protected_data.cbData);
  LocalFree(protected_data.pbData);
  return result == ERROR_SUCCESS;
}

bool HasProtectedUnlockPassword() {
  HKEY connector_key = nullptr;
  LONG result = RegOpenKeyExW(HKEY_CURRENT_USER, kConnectorRegistryPath, 0,
                              KEY_QUERY_VALUE, &connector_key);
  if (result != ERROR_SUCCESS || connector_key == nullptr) {
    return false;
  }

  result = RegQueryValueExW(connector_key, kRemoteUnlockSecretValueName, nullptr,
                            nullptr, nullptr, nullptr);
  RegCloseKey(connector_key);
  return result == ERROR_SUCCESS;
}

bool ClearProtectedUnlockPassword() {
  HKEY connector_key = nullptr;
  LONG result = RegOpenKeyExW(HKEY_CURRENT_USER, kConnectorRegistryPath, 0,
                              KEY_SET_VALUE, &connector_key);
  if (result != ERROR_SUCCESS || connector_key == nullptr) {
    return result == ERROR_FILE_NOT_FOUND;
  }

  result = RegDeleteValueW(connector_key, kRemoteUnlockSecretValueName);
  RegCloseKey(connector_key);
  return result == ERROR_SUCCESS || result == ERROR_FILE_NOT_FOUND;
}

std::optional<std::wstring> ReadProtectedUnlockPassword() {
  HKEY connector_key = nullptr;
  LONG result = RegOpenKeyExW(HKEY_CURRENT_USER, kConnectorRegistryPath, 0,
                              KEY_QUERY_VALUE, &connector_key);
  if (result != ERROR_SUCCESS || connector_key == nullptr) {
    return std::nullopt;
  }

  DWORD type = 0;
  DWORD size = 0;
  result = RegQueryValueExW(connector_key, kRemoteUnlockSecretValueName, nullptr,
                            &type, nullptr, &size);
  if (result != ERROR_SUCCESS || type != REG_BINARY || size == 0) {
    RegCloseKey(connector_key);
    return std::nullopt;
  }

  std::vector<BYTE> protected_bytes(size);
  result = RegQueryValueExW(connector_key, kRemoteUnlockSecretValueName, nullptr,
                            &type, protected_bytes.data(), &size);
  RegCloseKey(connector_key);
  if (result != ERROR_SUCCESS || type != REG_BINARY) {
    SecureZeroMemory(protected_bytes.data(), protected_bytes.size());
    return std::nullopt;
  }

  DATA_BLOB protected_data = {};
  protected_data.cbData = size;
  protected_data.pbData = protected_bytes.data();

  DATA_BLOB plain = {};
  const BOOL unprotected_ok =
      CryptUnprotectData(&protected_data, nullptr, nullptr, nullptr, nullptr,
                         CRYPTPROTECT_UI_FORBIDDEN, &plain);
  SecureZeroMemory(protected_bytes.data(), protected_bytes.size());
  if (unprotected_ok != TRUE || plain.pbData == nullptr || plain.cbData == 0) {
    return std::nullopt;
  }

  std::wstring password(
      reinterpret_cast<wchar_t*>(plain.pbData),
      plain.cbData / sizeof(wchar_t));
  while (!password.empty() && password.back() == L'\0') {
    password.pop_back();
  }

  SecureZeroMemory(plain.pbData, plain.cbData);
  LocalFree(plain.pbData);
  if (password.empty()) {
    return std::nullopt;
  }
  return password;
}

bool UnlockComputerWithSavedPassword() {
  auto password = ReadProtectedUnlockPassword();
  if (!password.has_value()) {
    return false;
  }

  const DWORD active_session = WTSGetActiveConsoleSessionId();
  if (active_session == 0xFFFFFFFF) {
    SecureZeroMemory(password->data(), password->size() * sizeof(wchar_t));
    return false;
  }

  const BOOL connected =
      WTSConnectSessionW(active_session, WTS_CURRENT_SESSION,
                         const_cast<LPWSTR>(password->c_str()), TRUE);
  SecureZeroMemory(password->data(), password->size() * sizeof(wchar_t));
  return connected == TRUE;
}

bool ShowSystemNotification(const std::string& title, const std::string& body) {
  NOTIFYICONDATAW data = {};
  data.cbSize = sizeof(NOTIFYICONDATAW);
  data.hWnd = NotificationHostWindow();
  if (data.hWnd == nullptr) {
    return false;
  }
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

int64_t TimelineAgeMs(
    winrt::Windows::Foundation::DateTime last_updated_time) {
  const auto now = winrt::clock::now();
  if (last_updated_time > now) {
    return 0;
  }

  return std::chrono::duration_cast<std::chrono::milliseconds>(
             now - last_updated_time)
      .count();
}

EncodableMap ReadMediaStatusOnWorker() {
  EncodableMap status;

  try {
    winrt::init_apartment(winrt::apartment_type::multi_threaded);
    auto manager =
        media_control::GlobalSystemMediaTransportControlsSessionManager::
            RequestAsync()
                .get();
    auto session = manager.GetCurrentSession();
    if (!session) {
      return status;
    }

    auto media_properties = session.TryGetMediaPropertiesAsync().get();
    auto timeline = session.GetTimelineProperties();
    auto playback_info = session.GetPlaybackInfo();
    const int64_t start_ms = TimeSpanToMs(timeline.StartTime());
    const int64_t end_ms = TimeSpanToMs(timeline.EndTime());
    const int64_t duration_ms = std::max<int64_t>(0, end_ms - start_ms);

    const bool is_playing =
        playback_info.PlaybackStatus() ==
        media_control::GlobalSystemMediaTransportControlsSessionPlaybackStatus::
            Playing;
    const int64_t timeline_age_ms =
        is_playing ? TimelineAgeMs(timeline.LastUpdatedTime()) : 0;
    const int64_t position_ms =
        ClampTimelineMs(TimeSpanToMs(timeline.Position()) - start_ms +
                            timeline_age_ms,
                        duration_ms);

    status[EncodableValue("title")] =
        EncodableValue(HStringToUtf8(media_properties.Title()));
    status[EncodableValue("artist")] =
        EncodableValue(HStringToUtf8(media_properties.Artist()));
    status[EncodableValue("album")] =
        EncodableValue(HStringToUtf8(media_properties.AlbumTitle()));
    status[EncodableValue("sourceApp")] =
        EncodableValue(HStringToUtf8(session.SourceAppUserModelId()));
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

bool SeekCurrentMediaOnWorker(int64_t position_ms) {
  try {
    winrt::init_apartment(winrt::apartment_type::multi_threaded);
    auto manager =
        media_control::GlobalSystemMediaTransportControlsSessionManager::
            RequestAsync()
                .get();
    auto session = manager.GetCurrentSession();
    if (!session) {
      return false;
    }

    const int64_t position_100ns = std::max<int64_t>(0, position_ms) * 10000;
    return session.TryChangePlaybackPositionAsync(position_100ns).get();
  } catch (const winrt::hresult_error&) {
    return false;
  }
}

bool SeekCurrentMedia(int64_t position_ms) {
  return std::async(std::launch::async, [position_ms]() {
    return SeekCurrentMediaOnWorker(position_ms);
  }).get();
}

bool SetMasterVolume(double percent) {
  IAudioEndpointVolume* volume = CreateEndpointVolume();
  if (volume == nullptr) {
    return false;
  }

  const float scalar =
      static_cast<float>(std::clamp(percent, 0.0, 100.0) / 100.0);
  const HRESULT result = volume->SetMasterVolumeLevelScalar(scalar, nullptr);
  volume->Release();
  return SUCCEEDED(result);
}

bool GetMasterVolume(double* percent) {
  IAudioEndpointVolume* volume = CreateEndpointVolume();
  if (volume == nullptr) {
    return false;
  }

  float scalar = 0;
  const HRESULT result = volume->GetMasterVolumeLevelScalar(&scalar);
  volume->Release();
  if (FAILED(result)) {
    return false;
  }

  *percent = static_cast<double>(scalar * 100.0f);
  return true;
}

bool GetMuteState(bool* muted) {
  IAudioEndpointVolume* volume = CreateEndpointVolume();
  if (volume == nullptr) {
    return false;
  }

  BOOL mute_value = FALSE;
  const HRESULT result = volume->GetMute(&mute_value);
  volume->Release();
  if (FAILED(result)) {
    return false;
  }

  *muted = mute_value == TRUE;
  return true;
}

struct WindowEnumState {
  EncodableList windows;
};

BOOL CALLBACK EnumVisibleWindows(HWND hwnd, LPARAM lparam) {
  if (!IsWindowVisible(hwnd) || hwnd == GetShellWindow()) {
    return TRUE;
  }

  const LONG ex_style = GetWindowLongW(hwnd, GWL_EXSTYLE);
  if ((ex_style & WS_EX_TOOLWINDOW) != 0) {
    return TRUE;
  }

  const std::wstring title = ReadWindowTitle(hwnd);
  if (title.empty()) {
    return TRUE;
  }

  DWORD pid = 0;
  GetWindowThreadProcessId(hwnd, &pid);

  WindowEnumState* state = reinterpret_cast<WindowEnumState*>(lparam);
  EncodableMap entry;

  std::ostringstream id_stream;
  id_stream << reinterpret_cast<std::uintptr_t>(hwnd);

  entry[EncodableValue("id")] = EncodableValue(id_stream.str());
  entry[EncodableValue("title")] = EncodableValue(WideToUtf8(title));
  entry[EncodableValue("process")] =
      EncodableValue(WideToUtf8(ReadProcessName(pid)));
  entry[EncodableValue("pid")] = EncodableValue(static_cast<int32_t>(pid));
  state->windows.push_back(EncodableValue(entry));

  return TRUE;
}

EncodableList ListVisibleWindows() {
  WindowEnumState state;
  EnumWindows(EnumVisibleWindows, reinterpret_cast<LPARAM>(&state));
  return state.windows;
}

void SuccessBool(std::unique_ptr<MethodResult<EncodableValue>> result,
                 bool value = true) {
  result->Success(EncodableValue(value));
}

void HandleMethodCall(
    const MethodCall<EncodableValue>& call,
    std::unique_ptr<MethodResult<EncodableValue>> result) {
  const std::string& method = call.method_name();

  if (method == "mediaPlayPause") {
    SendVirtualKey(VK_MEDIA_PLAY_PAUSE);
    SuccessBool(std::move(result));
    return;
  }

  if (method == "mediaNext") {
    SendVirtualKey(VK_MEDIA_NEXT_TRACK);
    SuccessBool(std::move(result));
    return;
  }

  if (method == "mediaPrevious") {
    SendVirtualKey(VK_MEDIA_PREV_TRACK);
    SuccessBool(std::move(result));
    return;
  }

  if (method == "mediaSeek") {
    const double position = ReadDoubleArgument(call.arguments(), "positionMs", 0);
    SuccessBool(std::move(result),
                SeekCurrentMedia(static_cast<int64_t>(position)));
    return;
  }

  if (method == "getMediaStatus") {
    result->Success(EncodableValue(ReadMediaStatus()));
    return;
  }

  if (method == "volumeUp") {
    SendVirtualKey(VK_VOLUME_UP);
    SuccessBool(std::move(result));
    return;
  }

  if (method == "volumeDown") {
    SendVirtualKey(VK_VOLUME_DOWN);
    SuccessBool(std::move(result));
    return;
  }

  if (method == "volumeMute") {
    SendVirtualKey(VK_VOLUME_MUTE);
    SuccessBool(std::move(result));
    return;
  }

  if (method == "setVolume") {
    const double level = ReadDoubleArgument(call.arguments(), "level", 50);
    SuccessBool(std::move(result), SetMasterVolume(level));
    return;
  }

  if (method == "getVolume") {
    double volume = 0;
    if (GetMasterVolume(&volume)) {
      result->Success(EncodableValue(volume));
    } else {
      result->Success(EncodableValue());
    }
    return;
  }

  if (method == "isMuted") {
    bool muted = false;
    if (GetMuteState(&muted)) {
      result->Success(EncodableValue(muted));
    } else {
      result->Success(EncodableValue());
    }
    return;
  }

  if (method == "listWindows") {
    result->Success(EncodableValue(ListVisibleWindows()));
    return;
  }

  if (method == "lockComputer") {
    SuccessBool(std::move(result), LockWorkStation() == TRUE);
    return;
  }

  if (method == "unlockComputer") {
    SuccessBool(std::move(result), UnlockComputerWithSavedPassword());
    return;
  }

  if (method == "saveWindowsUnlockPassword") {
    const std::string password =
        ReadStringArgument(call.arguments(), "password", "");
    SuccessBool(std::move(result), SaveProtectedUnlockPassword(password));
    return;
  }

  if (method == "hasWindowsUnlockPassword") {
    SuccessBool(std::move(result), HasProtectedUnlockPassword());
    return;
  }

  if (method == "clearWindowsUnlockPassword") {
    SuccessBool(std::move(result), ClearProtectedUnlockPassword());
    return;
  }

  if (method == "setAutoStart") {
    const bool enabled = ReadBoolArgument(call.arguments(), "enabled", false);
    SuccessBool(std::move(result), SetAutoStartEnabled(enabled));
    return;
  }

  if (method == "isAutoStartEnabled") {
    SuccessBool(std::move(result), IsAutoStartEnabled());
    return;
  }

  if (method == "showSystemNotification") {
    const std::string title =
        ReadStringArgument(call.arguments(), "title", "Connector");
    const std::string body = ReadStringArgument(call.arguments(), "body", "");
    SuccessBool(std::move(result), ShowSystemNotification(title, body));
    return;
  }

  result->NotImplemented();
}

}  // namespace

void RegisterConnectorPlatformChannel(flutter::FlutterEngine* engine) {
  static std::unique_ptr<MethodChannel<EncodableValue>> channel;
  channel = std::make_unique<MethodChannel<EncodableValue>>(
      engine->messenger(), kChannelName, &StandardMethodCodec::GetInstance());
  channel->SetMethodCallHandler(HandleMethodCall);
}
