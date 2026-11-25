#pragma once

#include "file_bridge.hpp"

#include <atomic>
#include <chrono>
#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace pz2 {

// Lua <-> DLL bridge through a Lua table used as shared memory.
//
// Retail Planet Zoo 2 disables api.debug file I/O and Lua HTTP, so Lua has no I/O of its own. Lua can
// however write integers into a table's array part, which sits at a fixed address (Lua's GC never
// moves objects and the table is never resized). The DLL finds that array once by its magic values
// and both sides then exchange the same text-line protocol as file_bridge.hpp through two rings.
//
// Table layout (Lua 1-based slot index; every slot holds a Lua integer):
//   1..4   kMemMagic + 1 .. + 4   (discovery pattern; the stride between them gives the TValue size)
//   5      DLL claim nonce        (DLL writes; Lua waits for non-zero)
//   6      Lua heartbeat          (Lua increments every frame; proves a found table is live, once)
//   7      protocol version       (Lua writes kMemVersion)
//   9/10   Lua -> DLL ring head (Lua) / tail (DLL), in slots
//   11/12  DLL -> Lua ring head (DLL) / tail (Lua), in slots
//   17 ..  Lua -> DLL data, kMemRingSlots slots; then DLL -> Lua data, kMemRingSlots slots
// Each data slot carries 8 bytes of text, little-endian. Producers pad a finished batch with '\n'.
inline constexpr std::int64_t kMemMagic = 0x5A32434F4F500000LL;
inline constexpr std::int64_t kMemVersion = 1;
inline constexpr std::size_t kMemRingSlots = 8192;
inline constexpr std::size_t kMemHeaderSlots = 16;
inline constexpr std::size_t kMemTotalSlots = kMemHeaderSlots + 2 * kMemRingSlots;

// Pure helpers (selftest): find the magic run in a memory image; returns {offset, stride} or {npos, 0}.
struct MagicHit {
    std::size_t offset;
    std::size_t stride;
};
MagicHit findMemMagic(const std::uint8_t* data, std::size_t size);

class MemBridge {
public:
    using Clock = std::chrono::steady_clock;

    // Moves text between the shared table and the protocol core. Call often from the IPC thread.
    void poll(FileBridge& protocol, const FileBridge::Deliver& deliver, Clock::time_point now);
    bool connected() const { return base_ != nullptr; }

private:
    void startDiscovery();
    void adopt(std::uint8_t* base, std::size_t stride);
    void lose(const char* why, FileBridge& protocol);
    bool readSlots(std::size_t first, std::size_t count, std::vector<std::int64_t>& out) const;
    bool writeSlots(std::size_t first, const std::int64_t* values, std::size_t count);

    std::uint8_t* base_ = nullptr; // address of slot 1's TValue
    std::size_t stride_ = 0;
    std::vector<std::uint8_t> tagBytes_; // bytes after the 8-byte value in an integer TValue
    std::int64_t outTail_ = 0;
    std::int64_t inHead_ = 0;
    std::int64_t lastBeat_ = 0;
    bool verified_ = false;
    Clock::time_point lastBeatChange_{};
    Clock::time_point nextDiscovery_{};
    std::string rxPartial_;
    std::string txBacklog_;

    // Discovery runs on a worker thread (a full scan takes seconds).
    std::atomic<bool> scanning_{false};
    std::atomic<std::uint8_t*> foundBase_{nullptr};
    std::atomic<std::size_t> foundStride_{0};
};

} // namespace pz2
