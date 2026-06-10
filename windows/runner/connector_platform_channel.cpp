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
constexpr wchar_t kRunKeyPath[] = L"Software\\Microsoft\\Windows\\CurrentVersion\\Run";
constexpr wchar_t kAutoStartValueName[] = L"Connector";
constexpr wchar_t kConnectorRegistryPath[] = L"Software\\Connector";
constexpr wchar_t kRemoteUnlockSecretValueName[] = L"RemoteUnlockSecret";
constexpr wchar_t kNotificationWindowClass[] = L"ConnectorNotificationWindow";

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

void SendHardwareKey(wchar_t ch) {
  WORD vk = 0;
  bool shift = false;
  if (ch >= L'0' && ch <= L'9') vk = 0x30 + (ch - L'0');
  else if (ch >= L'a' && ch <= L'z') { vk = 0x41 + (ch - L'a'); shift = false; }
  else if (ch >= L'A' && ch <= L'Z') { vk = 0x41 + (ch - L'A'); shift = true; }
  else if (ch == L' ') vk = VK_SPACE;
  else if (ch == L'!') { vk = 0x21; shift = true; }
  else if (ch == L'@') { vk = 0x40; shift = true; }
  else if (ch == L'#') { vk = 0x23; shift = true; }
  else if (ch == L'$') { vk = 0x24; shift = true; }
  else if (ch == L'%') { vk = 0x25; shift = true; }
  else if (ch == L'^') { vk = 0x26; shift = true; }
  else if (ch == L'&') { vk = 0x27; shift = true; }
  else if (ch == L'*') { vk = 0x2A; shift = true; }
  else if (ch == L'(') { vk = 0x28; shift = true; }
  else if (ch == L')') { vk = 0x29; shift = true; }
  else if (ch == L'_') { vk = VK_OEM_PLUS; shift = false; }
  else if (ch == L'-') { vk = VK_OEM_MINUS; shift = false; }
  else if (ch == L'=') { vk = VK_OEM_PLUS; shift = false; }
  else if (ch == L'+') { vk = VK_OEM_PLUS; shift = true; }
  else if (ch == L'[') { vk = VK_OEM_1; shift = false; }
  else if (ch == L'{') { vk = VK_OEM_1; shift = true; }
  else if (ch == L']') { vk = VK_OEM_6; shift = false; }
  else if (ch == L'}') { vk = VK_OEM_6; shift = true; }
  else if (ch == L'\\') { vk = VK_OEM_5; shift = false; }
  else if (ch == L'|') { vk = VK_OEM_5; shift = true; }
  else if (ch == L';') { vk = VK_OEM_1; shift = false; }
  else if (ch == L':') { vk = VK_OEM_1; shift = true; }
  else if (ch == L'\"') { vk = VK_OEM_2; shift = true; }
  else if (ch == L'\'') { vk = VK_OEM_7; shift = false; }
  else if (ch == L',') { vk = VK_OEM_COMMA; shift = false; }
  else if (ch == L'<') { vk = VK_OEM_COMMA; shift = true; }
  else if (ch == L'.') { vk = VK_OEM_PERIOD; shift = false; }
  else if (ch == L'>') { vk = VK_OEM_PERIOD; shift = true; }
  else if (ch == L'/') { vk = VK_OEM_2; shift = false; }
  else if (ch == L'?') { vk = VK_OEM_2; shift = true; }
  if (vk == 0) return;
  if (shift) SendVirtualKey(VK_SHIFT);
  SendVirtualKey(vk);
  if (shift) SendVirtualKey(VK_SHIFT);
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

bool SaveProtectedUnlockPassword(const std::string& password_utf8) {
  std::wstring password = Utf8ToWide(password_utf8);
  if (password.empty()) return false;
  DATA_BLOB plain = {};
  plain.cbData = static_cast<DWORD>((password.size() + 1) * sizeof(wchar_t));
  plain.pbData = reinterpret_cast<BYTE*>(password.data());
  DATA_BLOB protected_data = {};
  const BOOL protected_ok = CryptProtectData(&plain, L"Connector remote unlock password", nullptr, nullptr, nullptr, CRYPTPROTECT_UI_FORBIDDEN, &protected_data);
  SecureZeroMemory(password.data(), password.size() * sizeof(wchar_t));
  if (protected_ok != TRUE) return false;
  HKEY connector_key = nullptr;
  LONG result = RegCreateKeyExW(HKEY_CURRENT_USER, kConnectorRegistryPath, 0, nullptr, 0, KEY_SET_VALUE, nullptr, &connector_key, nullptr);
  if (result == ERROR_SUCCESS && connector_key != nullptr) {
    result = RegSetValueExW(connector_key, kRemoteUnlockSecretValueName, 0, REG_BINARY, protected_data.pbData, protected_data.cbData);
  }
  if (connector_key != nullptr) RegCloseKey(connector_key);
  SecureZeroMemory(protected_data.pbData, protected_data.cbData);
  LocalFree(protected_data.pbData);
  return result == ERROR_SUCCESS;
}

bool HasProtectedUnlockPassword() {
  HKEY connector_key = nullptr;
  LONG result = RegOpenKeyExW(HKEY_CURRENT_USER, kConnectorRegistryPath, 0, KEY_QUERY_VALUE, &connector_key);
  if (result != ERROR_SUCCESS || connector_key == nullptr) return false;
  result = RegQueryValueExW(connector_key, kRemoteUnlockSecretValueName,