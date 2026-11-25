#pragma once

#include <array>
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <utility>
#include <vector>

namespace pz2 {

// Lock-free single-producer / single-consumer ring buffer.
// Exactly one thread may call push() and exactly one (other) thread may call pop().
// One slot stays empty to tell "full" from "empty", so usable capacity is Capacity - 1.
#pragma warning(push)
#pragma warning(disable : 4324) // padding added by alignas: intentional, keeps head/tail on separate cache lines
template <typename T, std::size_t Capacity>
class SPSCQueue {
    static_assert(Capacity >= 2 && (Capacity & (Capacity - 1)) == 0, "Capacity must be a power of two");
    static constexpr std::size_t kMask = Capacity - 1;

public:
    bool push(T&& value) {
        const std::size_t head = head_.load(std::memory_order_relaxed);
        const std::size_t next = (head + 1) & kMask;
        if (next == tail_.load(std::memory_order_acquire)) {
            return false; // full
        }
        slots_[head] = std::move(value);
        head_.store(next, std::memory_order_release);
        return true;
    }

    std::optional<T> pop() {
        const std::size_t tail = tail_.load(std::memory_order_relaxed);
        if (tail == head_.load(std::memory_order_acquire)) {
            return std::nullopt; // empty
        }
        std::optional<T> value(std::move(slots_[tail]));
        tail_.store((tail + 1) & kMask, std::memory_order_release);
        return value;
    }

private:
    alignas(64) std::atomic<std::size_t> head_{0}; // written by producer only
    alignas(64) std::atomic<std::size_t> tail_{0}; // written by consumer only
    alignas(64) std::array<T, Capacity> slots_{};
};
#pragma warning(pop)

enum class MsgKind : std::uint8_t {
    Packet, // data = [PacketType byte][payload bytes]
    Json,   // data = UTF-8 JSON text (control commands / status events)
};

struct NetMessage {
    MsgKind kind = MsgKind::Packet;
    std::vector<std::uint8_t> data;
};

// Steam thread -> IPC thread (remote packets + status events for the game UI/Lua).
inline SPSCQueue<NetMessage, 4096> g_IncomingQueue;
// IPC thread -> Steam thread (local actions + control commands from the game UI/Lua).
inline SPSCQueue<NetMessage, 4096> g_OutgoingQueue;

// Echo-suppression guard. Lua sends {"cmd":"apply_begin"} before replaying a remote action and
// {"cmd":"apply_end"} after; while set, outgoing action packets are dropped instead of queued.
inline std::atomic<bool> g_IsApplyingRemoteAction{false};
// GetTickCount64() at the last apply_end; the engine reacts to a commit a few frames after it.
inline std::atomic<unsigned long long> g_RemoteApplyEndTick{0};

// RAII form of the guard for any C++ code path that applies remote actions directly.
class RemoteApplyScope {
public:
    RemoteApplyScope() { g_IsApplyingRemoteAction.store(true, std::memory_order_release); }
    ~RemoteApplyScope() { g_IsApplyingRemoteAction.store(false, std::memory_order_release); }
    RemoteApplyScope(const RemoteApplyScope&) = delete;
    RemoteApplyScope& operator=(const RemoteApplyScope&) = delete;
};

} // namespace pz2
