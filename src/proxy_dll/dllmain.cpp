// version.dll proxy: forwards all 17 System32 version.dll exports and, inside PlanetZoo2.exe,
// starts the PZ2-Coop Steam P2P + IPC threads.

#include <windows.h>
#include <winver.h>

#include <cstdint>
#include <cwchar>

#include "diag.hpp"
#include "ipc_bridge.hpp"
#include "steam_p2p.hpp"
#include "ui_overlay.hpp"
#include "vehicle_patch.hpp"

namespace {

HMODULE realVersionDll() {
    // Loaded lazily on first forwarded call, never inside DllMain (loader lock).
    static const HMODULE module = [] {
        wchar_t path[MAX_PATH] = {};
        const UINT len = GetSystemDirectoryW(path, MAX_PATH);
        if (len == 0 || len >= MAX_PATH - 16) {
            return HMODULE{};
        }
        wcscat_s(path, L"\\version.dll");
        return LoadLibraryW(path);
    }();
    return module;
}

template <typename Fn>
Fn realExport(const char* name) {
    const HMODULE module = realVersionDll();
    return module != nullptr ? reinterpret_cast<Fn>(GetProcAddress(module, name)) : nullptr;
}

bool isGameProcess() {
    wchar_t path[MAX_PATH] = {};
    const DWORD len = GetModuleFileNameW(nullptr, path, MAX_PATH);
    if (len == 0 || len >= MAX_PATH) {
        return false;
    }
    const wchar_t* name = std::wcsrchr(path, L'\\');
    name = name != nullptr ? name + 1 : path;
    // crash_reporter.exe etc. in the same folder also load this DLL; only the game gets networking.
    return _wcsicmp(name, L"PlanetZoo2.exe") == 0;
}

} // namespace

// Each forwarder resolves the real export once, using the exact winver.h signature.
#define PZ2_FORWARD(name, ...)                                                   \
    static const auto real = realExport<decltype(&::name)>(#name);               \
    if (real == nullptr) {                                                       \
        SetLastError(ERROR_PROC_NOT_FOUND);                                      \
        return 0;                                                                \
    }                                                                            \
    return real(__VA_ARGS__)

extern "C" {

BOOL WINAPI proxy_GetFileVersionInfoA(LPCSTR file, DWORD handle, DWORD len, LPVOID data) {
    PZ2_FORWARD(GetFileVersionInfoA, file, handle, len, data);
}

// Undocumented export with no public prototype; every argument is register/pointer-sized,
// so pass six through untouched.
// ponytail: assumes <= 6 integer args; revisit if Microsoft ever documents a longer signature.
std::uintptr_t WINAPI proxy_GetFileVersionInfoByHandle(std::uintptr_t a, std::uintptr_t b, std::uintptr_t c,
                                                       std::uintptr_t d, std::uintptr_t e, std::uintptr_t f) {
    using Fn = std::uintptr_t(WINAPI*)(std::uintptr_t, std::uintptr_t, std::uintptr_t, std::uintptr_t, std::uintptr_t,
                                       std::uintptr_t);
    static const auto real = realExport<Fn>("GetFileVersionInfoByHandle");
    if (real == nullptr) {
        SetLastError(ERROR_PROC_NOT_FOUND);
        return 0;
    }
    return real(a, b, c, d, e, f);
}

BOOL WINAPI proxy_GetFileVersionInfoExA(DWORD flags, LPCSTR file, DWORD handle, DWORD len, LPVOID data) {
    PZ2_FORWARD(GetFileVersionInfoExA, flags, file, handle, len, data);
}

BOOL WINAPI proxy_GetFileVersionInfoExW(DWORD flags, LPCWSTR file, DWORD handle, DWORD len, LPVOID data) {
    PZ2_FORWARD(GetFileVersionInfoExW, flags, file, handle, len, data);
}

DWORD WINAPI proxy_GetFileVersionInfoSizeA(LPCSTR file, LPDWORD handle) {
    PZ2_FORWARD(GetFileVersionInfoSizeA, file, handle);
}

DWORD WINAPI proxy_GetFileVersionInfoSizeExA(DWORD flags, LPCSTR file, LPDWORD handle) {
    PZ2_FORWARD(GetFileVersionInfoSizeExA, flags, file, handle);
}

DWORD WINAPI proxy_GetFileVersionInfoSizeExW(DWORD flags, LPCWSTR file, LPDWORD handle) {
    PZ2_FORWARD(GetFileVersionInfoSizeExW, flags, file, handle);
}

DWORD WINAPI proxy_GetFileVersionInfoSizeW(LPCWSTR file, LPDWORD handle) {
    PZ2_FORWARD(GetFileVersionInfoSizeW, file, handle);
}

BOOL WINAPI proxy_GetFileVersionInfoW(LPCWSTR file, DWORD handle, DWORD len, LPVOID data) {
    PZ2_FORWARD(GetFileVersionInfoW, file, handle, len, data);
}

DWORD WINAPI proxy_VerFindFileA(DWORD flags, LPCSTR fileName, LPCSTR winDir, LPCSTR appDir, LPSTR curDir,
                                PUINT curDirLen, LPSTR destDir, PUINT destDirLen) {
    PZ2_FORWARD(VerFindFileA, flags, fileName, winDir, appDir, curDir, curDirLen, destDir, destDirLen);
}

DWORD WINAPI proxy_VerFindFileW(DWORD flags, LPCWSTR fileName, LPCWSTR winDir, LPCWSTR appDir, LPWSTR curDir,
                                PUINT curDirLen, LPWSTR destDir, PUINT destDirLen) {
    PZ2_FORWARD(VerFindFileW, flags, fileName, winDir, appDir, curDir, curDirLen, destDir, destDirLen);
}

DWORD WINAPI proxy_VerInstallFileA(DWORD flags, LPCSTR srcFileName, LPCSTR destFileName, LPCSTR srcDir,
                                   LPCSTR destDir, LPCSTR curDir, LPSTR tmpFile, PUINT tmpFileLen) {
    PZ2_FORWARD(VerInstallFileA, flags, srcFileName, destFileName, srcDir, destDir, curDir, tmpFile, tmpFileLen);
}

DWORD WINAPI proxy_VerInstallFileW(DWORD flags, LPCWSTR srcFileName, LPCWSTR destFileName, LPCWSTR srcDir,
                                   LPCWSTR destDir, LPCWSTR curDir, LPWSTR tmpFile, PUINT tmpFileLen) {
    PZ2_FORWARD(VerInstallFileW, flags, srcFileName, destFileName, srcDir, destDir, curDir, tmpFile, tmpFileLen);
}

DWORD WINAPI proxy_VerLanguageNameA(DWORD lang, LPSTR name, DWORD size) {
    PZ2_FORWARD(VerLanguageNameA, lang, name, size);
}

DWORD WINAPI proxy_VerLanguageNameW(DWORD lang, LPWSTR name, DWORD size) {
    PZ2_FORWARD(VerLanguageNameW, lang, name, size);
}

BOOL WINAPI proxy_VerQueryValueA(LPCVOID block, LPCSTR subBlock, LPVOID* buffer, PUINT len) {
    PZ2_FORWARD(VerQueryValueA, block, subBlock, buffer, len);
}

BOOL WINAPI proxy_VerQueryValueW(LPCVOID block, LPCWSTR subBlock, LPVOID* buffer, PUINT len) {
    PZ2_FORWARD(VerQueryValueW, block, subBlock, buffer, len);
}

} // extern "C"

BOOL WINAPI DllMain(HINSTANCE instance, DWORD reason, LPVOID /*reserved*/) {
    if (reason == DLL_PROCESS_ATTACH) {
        DisableThreadLibraryCalls(instance);
        if (isGameProcess()) {
            // Pin ourselves: the worker threads must never outlive the module's code.
            HMODULE self = nullptr;
            GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_PIN,
                               reinterpret_cast<LPCWSTR>(&DllMain), &self);
            pz2::installDiagnostics(); // import-table patch only; no loading or locking here
            pz2::installAutotestInputHook(); // passthrough XInputGetState hook for headless vehicle autotests
            // Threads only start running after the loader lock is released.
            pz2::startDiagnosticScan();
            pz2::startUiOverlayBuild(); // patched game UI built from the player's own files
            pz2::startIpcBridge();
            pz2::startSteamP2P();
        }
    }
    return TRUE;
}
