#include "diag.hpp"
#include "spsc_queue.hpp"
#include "ui_overlay.hpp"

#include <windows.h>
#include <share.h>

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string_view>
#include <thread>
#include <vector>
#include <cwchar>
#include <cwctype>
#include <mutex>
#include <string>

namespace pz2 {

namespace {

using CreateFileWFn = decltype(&::CreateFileW);
CreateFileWFn g_CreateFileW = nullptr;
#ifdef PZ2COOP_DEV_DIAG
using CreateFileAFn = decltype(&::CreateFileA);
using CreateFile2Fn = decltype(&::CreateFile2);
using FindFirstFileWFn = decltype(&::FindFirstFileW);
using FindFirstFileExWFn = decltype(&::FindFirstFileExW);
using OutputDebugStringAFn = decltype(&::OutputDebugStringA);
using OutputDebugStringWFn = decltype(&::OutputDebugStringW);

CreateFileAFn g_CreateFileA = nullptr;
CreateFile2Fn g_CreateFile2 = nullptr;
FindFirstFileWFn g_FindFirstFileW = nullptr;
FindFirstFileExWFn g_FindFirstFileExW = nullptr;
OutputDebugStringAFn g_OutputDebugStringA = nullptr;
OutputDebugStringWFn g_OutputDebugStringW = nullptr;
#endif
using SetCursorPosFn = decltype(&::SetCursorPos);
SetCursorPosFn g_SetCursorPos = nullptr;
std::atomic<unsigned> g_cursorBlocks{0};
constexpr unsigned long long kCursorGraceMs = 750; // apply_end reaches the DLL up to ~50 ms late, plus a few frames

constexpr int kMaxOvldataLines = 60;
#ifdef PZ2COOP_DEV_DIAG
constexpr int kMaxDebugLines = 4000;
#endif
constexpr int kMaxPackLines = 2000;

std::mutex g_logMutex;
FILE* g_log = nullptr;
int g_ovldataLines = 0;
#ifdef PZ2COOP_DEV_DIAG
int g_debugLines = 0;
#endif
int g_packLines = 0;
thread_local bool t_inHook = false;

// Our own CRT I/O goes through the CRT's imports, not the exe's patched table, so no recursion.
void writeLine(const wchar_t* tag, const wchar_t* text) {
    std::lock_guard lock(g_logMutex);
    if (g_log == nullptr) {
        wchar_t path[MAX_PATH] = {};
        const DWORD len = GetModuleFileNameW(nullptr, path, MAX_PATH);
        std::wstring dir(path, len);
        dir = dir.substr(0, dir.find_last_of(L"\\/") + 1) + L"PZ2Coop";
        CreateDirectoryW(dir.c_str(), nullptr);
        // Keep the previous run's log: a test is often only reported after the game was restarted.
        MoveFileExW((dir + L"\\diag.log").c_str(), (dir + L"\\diag.prev.log").c_str(), MOVEFILE_REPLACE_EXISTING);
        g_log = _wfsopen((dir + L"\\diag.log").c_str(), L"w, ccs=UTF-8", _SH_DENYNO);
        if (g_log == nullptr) {
            return;
        }
    }
    std::fwprintf(g_log, L"%lu %s %s\n", GetTickCount(), tag, text);
    std::fflush(g_log);
}

bool containsNoCase(const wchar_t* haystack, const wchar_t* needle) {
    if (haystack == nullptr) {
        return false;
    }
    std::wstring h(haystack);
    for (auto& c : h) {
        c = static_cast<wchar_t>(std::towlower(c));
    }
    return h.find(needle) != std::wstring::npos;
}

void noteFile(const wchar_t* api, const wchar_t* path, bool ok) {
    if (t_inHook || path == nullptr) {
        return;
    }
    t_inHook = true;
    const bool ours = containsNoCase(path, L"pz2coop") && !containsNoCase(path, L"diag.log");
    bool log = false;
    {
        std::lock_guard lock(g_logMutex);
        if (ours && g_packLines < kMaxPackLines) {
            ++g_packLines;
            log = true;
        } else if (!ours && containsNoCase(path, L"ovldata") && g_ovldataLines < kMaxOvldataLines) {
            ++g_ovldataLines;
            log = true;
        }
    }
    if (log) {
        std::wstring line = std::wstring(api) + (ok ? L" ok   " : L" FAIL ") + path;
        writeLine(L"FILE", line.c_str());
    }
    t_inHook = false;
}

std::wstring widen(const char* s) {
    std::wstring out;
    if (s != nullptr) {
        const int n = MultiByteToWideChar(CP_UTF8, 0, s, -1, nullptr, 0);
        if (n > 1) {
            out.resize(static_cast<std::size_t>(n - 1));
            MultiByteToWideChar(CP_UTF8, 0, s, -1, out.data(), n);
        }
    }
    return out;
}

#ifdef PZ2COOP_DEV_DIAG
void noteDebug(const std::wstring& text) {
    if (t_inHook) {
        return;
    }
    t_inHook = true;
    bool log = false;
    {
        std::lock_guard lock(g_logMutex);
        if (g_debugLines < kMaxDebugLines) {
            ++g_debugLines;
            log = true;
        }
    }
    if (log) {
        std::wstring line = text;
        while (!line.empty() && (line.back() == L'\n' || line.back() == L'\r')) {
            line.pop_back();
        }
        writeLine(L"DBG ", line.c_str());
    }
    t_inHook = false;
}
#endif

HANDLE WINAPI hkCreateFileW(LPCWSTR path, DWORD access, DWORD share, LPSECURITY_ATTRIBUTES sa, DWORD disposition,
                            DWORD flags, HANDLE templ) {
    waitForUiOverlayIfOurs(path);
    const HANDLE h = g_CreateFileW(path, access, share, sa, disposition, flags, templ);
    const DWORD err = GetLastError();
    noteFile(L"CreateFileW", path, h != INVALID_HANDLE_VALUE);
    SetLastError(err);
    return h;
}

#ifdef PZ2COOP_DEV_DIAG
HANDLE WINAPI hkCreateFileA(LPCSTR path, DWORD access, DWORD share, LPSECURITY_ATTRIBUTES sa, DWORD disposition,
                            DWORD flags, HANDLE templ) {
    waitForUiOverlayIfOurs(widen(path).c_str());
    const HANDLE h = g_CreateFileA(path, access, share, sa, disposition, flags, templ);
    const DWORD err = GetLastError();
    noteFile(L"CreateFileA", widen(path).c_str(), h != INVALID_HANDLE_VALUE);
    SetLastError(err);
    return h;
}

HANDLE WINAPI hkCreateFile2(LPCWSTR path, DWORD access, DWORD share, DWORD disposition,
                            LPCREATEFILE2_EXTENDED_PARAMETERS params) {
    waitForUiOverlayIfOurs(path);
    const HANDLE h = g_CreateFile2(path, access, share, disposition, params);
    const DWORD err = GetLastError();
    noteFile(L"CreateFile2", path, h != INVALID_HANDLE_VALUE);
    SetLastError(err);
    return h;
}

HANDLE WINAPI hkFindFirstFileW(LPCWSTR path, LPWIN32_FIND_DATAW data) {
    const HANDLE h = g_FindFirstFileW(path, data);
    const DWORD err = GetLastError();
    noteFile(L"FindFirstFileW", path, h != INVALID_HANDLE_VALUE);
    SetLastError(err);
    return h;
}

HANDLE WINAPI hkFindFirstFileExW(LPCWSTR path, FINDEX_INFO_LEVELS level, LPVOID data, FINDEX_SEARCH_OPS op,
                                 LPVOID filter, DWORD flags) {
    const HANDLE h = g_FindFirstFileExW(path, level, data, op, filter, flags);
    const DWORD err = GetLastError();
    noteFile(L"FindFirstFileExW", path, h != INVALID_HANDLE_VALUE);
    SetLastError(err);
    return h;
}

void WINAPI hkOutputDebugStringA(LPCSTR text) {
    noteDebug(widen(text));
    g_OutputDebugStringA(text);
}

void WINAPI hkOutputDebugStringW(LPCWSTR text) {
    noteDebug(text != nullptr ? std::wstring(text) : std::wstring());
    g_OutputDebugStringW(text);
}
#endif

// Tester (2026-11-25): a friend's build made the engine warp the player's mouse pointer to it. Warps are
// dropped while a remote action applies and shortly after; the log line shows whether this was the cause.
BOOL WINAPI hkSetCursorPos(int x, int y) {
    const bool applying = g_IsApplyingRemoteAction.load(std::memory_order_acquire) ||
                          GetTickCount64() - g_RemoteApplyEndTick.load(std::memory_order_acquire) < kCursorGraceMs;
    if (!applying) {
        return g_SetCursorPos(x, y);
    }
    const unsigned blocked = ++g_cursorBlocks;
    if (blocked <= 20 || blocked % 100 == 0) {
        diagLog("cursor: SetCursorPos(" + std::to_string(x) + "," + std::to_string(y) +
                ") during a friend's action blocked (" + std::to_string(blocked) + " so far)");
    }
    return TRUE;
}

// Rewrites one entry in the module's import address table; keeps the original pointer.
template <class Fn>
void patchImport(HMODULE module, const char* dll, const char* function, Fn hook, Fn& original) {
    auto* base = reinterpret_cast<std::uint8_t*>(module);
    const auto* dos = reinterpret_cast<const IMAGE_DOS_HEADER*>(base);
    const auto* nt = reinterpret_cast<const IMAGE_NT_HEADERS*>(base + dos->e_lfanew);
    const IMAGE_DATA_DIRECTORY& dir = nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT];
    if (dir.VirtualAddress == 0) {
        return;
    }
    for (auto* desc = reinterpret_cast<const IMAGE_IMPORT_DESCRIPTOR*>(base + dir.VirtualAddress); desc->Name != 0;
         ++desc) {
        if (_stricmp(reinterpret_cast<const char*>(base + desc->Name), dll) != 0 ||
            desc->OriginalFirstThunk == 0) {
            continue;
        }
        auto* names = reinterpret_cast<const IMAGE_THUNK_DATA*>(base + desc->OriginalFirstThunk);
        auto* slots = reinterpret_cast<IMAGE_THUNK_DATA*>(base + desc->FirstThunk);
        for (; names->u1.AddressOfData != 0; ++names, ++slots) {
            if (IMAGE_SNAP_BY_ORDINAL(names->u1.Ordinal)) {
                continue;
            }
            const auto* byName = reinterpret_cast<const IMAGE_IMPORT_BY_NAME*>(base + names->u1.AddressOfData);
            if (std::strcmp(reinterpret_cast<const char*>(byName->Name), function) != 0) {
                continue;
            }
            DWORD oldProtect = 0;
            if (VirtualProtect(&slots->u1.Function, sizeof(slots->u1.Function), PAGE_READWRITE, &oldProtect)) {
                if (original == nullptr) {
                    original = reinterpret_cast<Fn>(slots->u1.Function);
                }
                slots->u1.Function = reinterpret_cast<ULONG_PTR>(hook);
                VirtualProtect(&slots->u1.Function, sizeof(slots->u1.Function), oldProtect, &oldProtect);
            }
        }
    }
}

#ifdef PZ2COOP_DEV_DIAG
// Finds the runtime-built marker our Lua keeps alive ("PZ2COOPALIVE" x3 ... "|END") in private RW memory.
// ReadProcessMemory instead of direct reads: the game may free a region mid-scan.
void scanForLuaMarkers() {
    std::string needle;
    for (int i = 0; i < 3; ++i) {
        needle += "PZ2COOP";
        needle += "ALIVE";
    }
    std::vector<std::string> seen;
    std::vector<char> buffer(4u << 20);
    for (int pass = 1; pass <= 12; ++pass) {
        Sleep(20000);
        const DWORD start = GetTickCount();
        std::size_t scannedMb = 0;
        MEMORY_BASIC_INFORMATION mbi{};
        for (auto* addr = static_cast<std::uint8_t*>(nullptr);
             VirtualQuery(addr, &mbi, sizeof(mbi)) == sizeof(mbi); addr = static_cast<std::uint8_t*>(mbi.BaseAddress) + mbi.RegionSize) {
            if (mbi.State != MEM_COMMIT || mbi.Type != MEM_PRIVATE || mbi.Protect != PAGE_READWRITE) {
                continue;
            }
            auto* base = static_cast<std::uint8_t*>(mbi.BaseAddress);
            for (SIZE_T off = 0; off < mbi.RegionSize; off += buffer.size() - 2048) {
                const SIZE_T want = std::min<SIZE_T>(buffer.size(), mbi.RegionSize - off);
                SIZE_T got = 0;
                if (!ReadProcessMemory(GetCurrentProcess(), base + off, buffer.data(), want, &got) || got == 0) {
                    break;
                }
                scannedMb += got >> 20;
                const std::string_view view(buffer.data(), got);
                for (std::size_t at = view.find(needle); at != std::string_view::npos; at = view.find(needle, at + 1)) {
                    const std::size_t end = view.find("|END", at);
                    if (end == std::string_view::npos || end - at > 2048) {
                        continue;
                    }
                    std::string hit(view.substr(at + needle.size(), end - at - needle.size()));
                    if (std::find(seen.begin(), seen.end(), hit) == seen.end()) {
                        seen.push_back(hit);
                        writeLine(L"LUA ", widen(hit.c_str()).c_str());
                    }
                }
                if (want < buffer.size()) {
                    break;
                }
            }
        }
        std::wstring summary = L"memory scan pass " + std::to_wstring(pass) + L": " + std::to_wstring(scannedMb) +
                               L" MB in " + std::to_wstring(GetTickCount() - start) + L" ms, markers found " +
                               std::to_wstring(seen.size());
        writeLine(L"SCAN", summary.c_str());
    }
}
#endif

} // namespace

void diagLog(std::string_view text) {
    writeLine(L"LOG ", widen(std::string(text).c_str()).c_str());
}

void* patchExeImport(const char* dll, const char* function, void* hook) {
    void* original = nullptr;
    patchImport(GetModuleHandleW(nullptr), dll, function, hook, original);
    return original;
}

void startDiagnosticScan() {
#ifdef PZ2COOP_DEV_DIAG
    std::thread(scanForLuaMarkers).detach();
#endif
}

void installDiagnostics() {
    const HMODULE exe = GetModuleHandleW(nullptr);
    // Minimal Release hooks: CreateFileW holds PZ2CoopUI.ovl opens until the runtime template fill finishes;
    // SetCursorPos blocks engine mouse warps while a remote action is being applied.
    patchImport(exe, "kernel32.dll", "CreateFileW", &hkCreateFileW, g_CreateFileW);
    patchImport(exe, "user32.dll", "SetCursorPos", &hkSetCursorPos, g_SetCursorPos);
#ifdef PZ2COOP_DEV_DIAG
    patchImport(exe, "kernel32.dll", "CreateFileA", &hkCreateFileA, g_CreateFileA);
    patchImport(exe, "kernel32.dll", "CreateFile2", &hkCreateFile2, g_CreateFile2);
    patchImport(exe, "kernel32.dll", "FindFirstFileW", &hkFindFirstFileW, g_FindFirstFileW);
    patchImport(exe, "kernel32.dll", "FindFirstFileExW", &hkFindFirstFileExW, g_FindFirstFileExW);
    patchImport(exe, "kernel32.dll", "OutputDebugStringA", &hkOutputDebugStringA, g_OutputDebugStringA);
    patchImport(exe, "kernel32.dll", "OutputDebugStringW", &hkOutputDebugStringW, g_OutputDebugStringW);
#endif
}

} // namespace pz2
