#include "vehicle_patch.hpp"

#include "diag.hpp"

#include <windows.h>

#include <array>
#include <atomic>
#include <cstring>
#include <mutex>
#include <string>

namespace pz2 {

namespace {

// Inside CarPhysicsComponentManager's obstacle-avoidance & keep-out check (PlanetZoo2.exe):
//   45 38 81 F1 00 00 00   cmp byte ptr [r9+0F1h], r8b
//   0F 85 3F 06 00 00      jne +0x63F   (early return when auto-brake/keep-out is disabled)
//
// Replacing the 6-byte `jne +0x63F` with `90 E9 3F 06 00 00` (`nop; jmp +0x63F`) skips:
//   1. The 4..25 m lookahead physics sweep that cuts throttle and slams auto-brakes meters before walls/props/animals.
//   2. The spatial/habitat keep-out volume check that brakes 4+ m before habitat walls or teleports the car to spawn.
// Real physical chassis rigidbody collisions in MainPhysicsWorld remain untouched.
constexpr std::array<std::uint8_t, 7> kPrefixBytes = {0x45, 0x38, 0x81, 0xF1, 0x00, 0x00, 0x00};
constexpr std::array<std::uint8_t, 6> kOriginalBranch = {0x0F, 0x85, 0x3F, 0x06, 0x00, 0x00};
constexpr std::array<std::uint8_t, 6> kPatchedBranch = {0x90, 0xE9, 0x3F, 0x06, 0x00, 0x00};
constexpr std::size_t kPatternLen = kPrefixBytes.size() + kOriginalBranch.size();

std::mutex g_patchMutex;
std::uint8_t* g_branchSite = nullptr;
bool g_scanned = false;
std::atomic<bool> g_removed{false};

// Locate the single unique occurrence of kPrefixBytes followed by either kOriginalBranch or kPatchedBranch.
std::uint8_t* findUniqueBranchSite(std::uint8_t* data, std::size_t size) {
    if (data == nullptr || size < kPatternLen) {
        return nullptr;
    }
    std::uint8_t* found = nullptr;
    const std::size_t limit = size - kPatternLen;
    for (std::size_t i = 0; i <= limit; ++i) {
        if (data[i] != kPrefixBytes[0]) {
            continue;
        }
        if (std::memcmp(data + i, kPrefixBytes.data(), kPrefixBytes.size()) != 0) {
            continue;
        }
        std::uint8_t* branch = data + i + kPrefixBytes.size();
        const bool isOrig = std::memcmp(branch, kOriginalBranch.data(), kOriginalBranch.size()) == 0;
        const bool isPatched = std::memcmp(branch, kPatchedBranch.data(), kPatchedBranch.size()) == 0;
        if (!isOrig && !isPatched) {
            continue;
        }
        if (found != nullptr) {
            return nullptr; // ambiguous match: refuse to patch
        }
        found = branch;
    }
    return found;
}

std::uint8_t* locateExeBranchSite() {
    if (g_scanned) {
        return g_branchSite;
    }
    g_scanned = true;
    const HMODULE exe = GetModuleHandleW(nullptr);
    if (exe == nullptr) {
        return nullptr;
    }
    auto* base = reinterpret_cast<std::uint8_t*>(exe);
    const auto* dos = reinterpret_cast<const IMAGE_DOS_HEADER*>(base);
    if (dos->e_magic != IMAGE_DOS_SIGNATURE) {
        return nullptr;
    }
    const auto* nt = reinterpret_cast<const IMAGE_NT_HEADERS*>(base + dos->e_lfanew);
    if (nt->Signature != IMAGE_NT_SIGNATURE) {
        return nullptr;
    }
    const auto* sec = IMAGE_FIRST_SECTION(nt);
    std::uint8_t* uniqueHit = nullptr;
    for (WORD i = 0; i < nt->FileHeader.NumberOfSections; ++i, ++sec) {
        if ((sec->Characteristics & IMAGE_SCN_MEM_EXECUTE) == 0) {
            continue;
        }
        const std::size_t secSize = sec->Misc.VirtualSize != 0 ? sec->Misc.VirtualSize : sec->SizeOfRawData;
        if (secSize < kPatternLen) {
            continue;
        }
        std::uint8_t* hit = findUniqueBranchSite(base + sec->VirtualAddress, secSize);
        if (hit != nullptr) {
            if (uniqueHit != nullptr) {
                diagLog("vehicle_patch: ambiguous signature across executable sections; skipping");
                return nullptr;
            }
            uniqueHit = hit;
        }
    }
    g_branchSite = uniqueHit;
    if (g_branchSite != nullptr) {
        const auto rva = static_cast<std::uintptr_t>(g_branchSite - base);
        char buf[96];
        std::snprintf(buf, sizeof(buf), "vehicle_patch: located CarPhysics auto-brake gate at RVA 0x%llx",
                      static_cast<unsigned long long>(rva));
        diagLog(buf);
    } else {
        diagLog("vehicle_patch: signature not found in PlanetZoo2.exe");
    }
    return g_branchSite;
}

// ---- In-process SendInput helper for headless autotest driving ----------------------------------
void sendScanKey(WORD scanCode, bool keyDown) {
    INPUT inp{};
    inp.type = INPUT_KEYBOARD;
    inp.ki.wVk = 0;
    inp.ki.wScan = scanCode;
    inp.ki.dwFlags = KEYEVENTF_SCANCODE | (keyDown ? 0u : KEYEVENTF_KEYUP);
    SendInput(1, &inp, sizeof(inp));
}

HWND findSelfMainWindow() {
    struct Ctx {
        DWORD pid;
        HWND hwnd;
    } ctx{GetCurrentProcessId(), nullptr};
    EnumWindows(
        [](HWND hwnd, LPARAM lp) -> BOOL {
            auto* c = reinterpret_cast<Ctx*>(lp);
            DWORD pid = 0;
            GetWindowThreadProcessId(hwnd, &pid);
            if (pid == c->pid && IsWindowVisible(hwnd)) {
                c->hwnd = hwnd;
                return FALSE;
            }
            return TRUE;
        },
        reinterpret_cast<LPARAM>(&ctx));
    return ctx.hwnd;
}

std::atomic<bool> g_autotestThrottle{false};

} // namespace

bool patchVehicleBoundsInBuffer(std::uint8_t* data, std::size_t size, bool remove) {
    std::uint8_t* branch = findUniqueBranchSite(data, size);
    if (branch == nullptr) {
        return false;
    }
    const auto& target = remove ? kPatchedBranch : kOriginalBranch;
    std::memcpy(branch, target.data(), target.size());
    return true;
}

bool setVehicleForcedBoundariesRemoved(bool remove) {
    std::lock_guard<std::mutex> lock(g_patchMutex);
    std::uint8_t* branch = locateExeBranchSite();
    if (branch == nullptr) {
        return false;
    }
    const auto& want = remove ? kPatchedBranch : kOriginalBranch;
    if (std::memcmp(branch, want.data(), want.size()) == 0) {
        g_removed.store(remove, std::memory_order_release);
        return true;
    }
    DWORD oldProtect = 0;
    if (!VirtualProtect(branch, want.size(), PAGE_EXECUTE_READWRITE, &oldProtect)) {
        diagLog("vehicle_patch: VirtualProtect failed (err=" + std::to_string(GetLastError()) + ")");
        return false;
    }
    std::memcpy(branch, want.data(), want.size());
    FlushInstructionCache(GetCurrentProcess(), branch, want.size());
    DWORD ignored = 0;
    VirtualProtect(branch, want.size(), oldProtect, &ignored);
    g_removed.store(remove, std::memory_order_release);
    diagLog(std::string("vehicle_patch: car-specific forced boundaries ") + (remove ? "REMOVED" : "RESTORED"));
    return true;
}

bool isVehicleForcedBoundariesRemoved() {
    return g_removed.load(std::memory_order_acquire);
}

void installAutotestInputHook() {}

void setAutotestDriveThrottle(bool active) {
    const bool prev = g_autotestThrottle.exchange(active, std::memory_order_acq_rel);
    if (active == prev) {
        return;
    }
    if (active) {
        if (HWND hwnd = findSelfMainWindow()) {
            if (GetForegroundWindow() != hwnd) {
                ShowWindow(hwnd, SW_RESTORE);
                SetForegroundWindow(hwnd);
                Sleep(350);
            }
        }
        sendScanKey(0x11, true); // 'W' scan code down
        Sleep(100);
        if (g_autotestThrottle.load(std::memory_order_acquire)) {
            sendScanKey(0x11, true); // reinforce in case mode transition just completed
        }
    } else {
        sendScanKey(0x11, false); // 'W' scan code up
    }
}

} // namespace pz2
