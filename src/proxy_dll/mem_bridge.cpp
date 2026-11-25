#include "mem_bridge.hpp"

#include "diag.hpp"

#include <windows.h>

#include <algorithm>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <random>
#include <string_view>
#include <thread>

namespace pz2 {

namespace {

constexpr std::size_t kSlotClaim = 5;
constexpr std::size_t kSlotBeat = 6;
constexpr std::size_t kSlotVersion = 7;
constexpr std::size_t kSlotOutHead = 9;
constexpr std::size_t kSlotOutTail = 10;
constexpr std::size_t kSlotInHead = 11;
constexpr std::size_t kSlotInTail = 12;
constexpr std::size_t kOutData = kMemHeaderSlots + 1;
constexpr std::size_t kInData = kOutData + kMemRingSlots;
constexpr auto kBeatTimeout = std::chrono::seconds(8);
constexpr auto kDiscoveryInterval = std::chrono::seconds(5);
constexpr std::size_t kStrides[] = {16, 24, 32};

std::int64_t load64(const std::uint8_t* p) {
    std::int64_t v;
    std::memcpy(&v, p, sizeof(v));
    return v;
}

// Stale tables from a previous Lua session (or our own scan buffer) are never adopted twice.
std::mutex g_rejectedMutex;
std::vector<std::uint8_t*> g_rejected;

bool isRejected(std::uint8_t* p) {
    std::lock_guard lock(g_rejectedMutex);
    return std::find(g_rejected.begin(), g_rejected.end(), p) != g_rejected.end();
}

void reject(std::uint8_t* p) {
    std::lock_guard lock(g_rejectedMutex);
    g_rejected.push_back(p);
}

std::uint8_t* scanProcess(std::size_t& strideOut) {
    std::vector<std::uint8_t> buffer(4u << 20);
    const auto* own = buffer.data();
    MEMORY_BASIC_INFORMATION mbi{};
    for (auto* addr = static_cast<std::uint8_t*>(nullptr); VirtualQuery(addr, &mbi, sizeof(mbi)) == sizeof(mbi);
         addr = static_cast<std::uint8_t*>(mbi.BaseAddress) + mbi.RegionSize) {
        if (mbi.State != MEM_COMMIT || mbi.Type != MEM_PRIVATE || mbi.Protect != PAGE_READWRITE) {
            continue;
        }
        auto* base = static_cast<std::uint8_t*>(mbi.BaseAddress);
        if (own >= base && own < base + mbi.RegionSize) {
            continue;
        }
        const SIZE_T overlap = 4 * 32;
        for (SIZE_T off = 0; off < mbi.RegionSize; off += buffer.size() - overlap) {
            const SIZE_T want = std::min<SIZE_T>(buffer.size(), mbi.RegionSize - off);
            SIZE_T got = 0;
            if (!ReadProcessMemory(GetCurrentProcess(), base + off, buffer.data(), want, &got) || got == 0) {
                break;
            }
            std::size_t from = 0;
            while (from < got) {
                const MagicHit hit = findMemMagic(buffer.data() + from, got - from);
                if (hit.stride == 0) {
                    break;
                }
                std::uint8_t* candidate = base + off + from + hit.offset;
                // Unclaimed tables only: a claimed one belongs to a dead or current session.
                std::int64_t claim = -1;
                SIZE_T n = 0;
                ReadProcessMemory(GetCurrentProcess(), candidate + (kSlotClaim - 1) * hit.stride, &claim, sizeof(claim), &n);
                if (n == sizeof(claim) && claim == 0 && !isRejected(candidate)) {
                    strideOut = hit.stride;
                    return candidate;
                }
                from += hit.offset + 8;
            }
            if (want < buffer.size()) {
                break;
            }
        }
    }
    return nullptr;
}

} // namespace

MagicHit findMemMagic(const std::uint8_t* data, std::size_t size) {
    const std::int64_t first = kMemMagic + 1;
    for (std::size_t at = 0; at + 8 <= size; at += 8) {
        if (load64(data + at) != first) {
            continue;
        }
        for (const std::size_t stride : kStrides) {
            if (at + 3 * stride + 8 > size) {
                continue;
            }
            if (load64(data + at + stride) == kMemMagic + 2 && load64(data + at + 2 * stride) == kMemMagic + 3 &&
                load64(data + at + 3 * stride) == kMemMagic + 4) {
                return {at, stride};
            }
        }
    }
    return {std::string_view::npos, 0};
}

void MemBridge::startDiscovery() {
    if (scanning_.exchange(true)) {
        return;
    }
    std::thread([this] {
        std::size_t stride = 0;
        std::uint8_t* found = scanProcess(stride);
        foundStride_.store(stride);
        foundBase_.store(found);
        scanning_.store(false);
    }).detach();
}

bool MemBridge::readSlots(std::size_t first, std::size_t count, std::vector<std::int64_t>& out) const {
    std::vector<std::uint8_t> raw(count * stride_);
    SIZE_T got = 0;
    if (!ReadProcessMemory(GetCurrentProcess(), base_ + (first - 1) * stride_, raw.data(), raw.size(), &got) ||
        got != raw.size()) {
        return false;
    }
    out.resize(count);
    for (std::size_t i = 0; i < count; ++i) {
        out[i] = load64(raw.data() + i * stride_);
    }
    return true;
}

// Writes whole TValues (value + the integer type tag copied at adoption) so Lua sees plain integers.
bool MemBridge::writeSlots(std::size_t first, const std::int64_t* values, std::size_t count) {
    std::vector<std::uint8_t> raw(count * stride_);
    for (std::size_t i = 0; i < count; ++i) {
        std::memcpy(raw.data() + i * stride_, &values[i], 8);
        std::memcpy(raw.data() + i * stride_ + 8, tagBytes_.data(), stride_ - 8);
    }
    SIZE_T done = 0;
    return WriteProcessMemory(GetCurrentProcess(), base_ + (first - 1) * stride_, raw.data(), raw.size(), &done) &&
           done == raw.size();
}

void MemBridge::adopt(std::uint8_t* base, std::size_t stride) {
    base_ = base;
    stride_ = stride;
    tagBytes_.assign(stride - 8, 0);
    SIZE_T n = 0;
    ReadProcessMemory(GetCurrentProcess(), base + 8, tagBytes_.data(), tagBytes_.size(), &n);
    std::vector<std::int64_t> header;
    if (!readSlots(1, kMemHeaderSlots, header) || header[kSlotVersion - 1] != kMemVersion) {
        diagLog("mem bridge: candidate rejected (header/version)");
        reject(base);
        base_ = nullptr;
        return;
    }
    outTail_ = header[kSlotOutTail - 1];
    inHead_ = header[kSlotInHead - 1];
    lastBeat_ = header[kSlotBeat - 1];
    lastBeatChange_ = Clock::now();
    verified_ = false;
    rxPartial_.clear();
    txBacklog_.clear();
    std::random_device rd;
    const std::int64_t claim = (static_cast<std::int64_t>(rd()) << 20) | 1;
    writeSlots(kSlotClaim, &claim, 1);
    char text[256];
    std::snprintf(text, sizeof(text), "mem bridge: adopted Lua table at %p, TValue stride %zu, beat %lld, tag bytes %02x %02x %02x %02x %02x %02x %02x %02x",
                  static_cast<void*>(base), stride, static_cast<long long>(lastBeat_), tagBytes_[0], tagBytes_[1],
                  tagBytes_[2], tagBytes_[3], tagBytes_[4], tagBytes_[5], tagBytes_[6], tagBytes_[7]);
    diagLog(text);
}

void MemBridge::lose(const char* why, FileBridge& protocol) {
    diagLog(std::string("mem bridge: lost Lua table (") + why + ")");
    reject(base_);
    base_ = nullptr;
    rxPartial_.clear();
    txBacklog_.clear();
    protocol.setExternalTransport(false);
}

void MemBridge::poll(FileBridge& protocol, const FileBridge::Deliver& deliver, Clock::time_point now) {
    if (base_ == nullptr) {
        if (std::uint8_t* found = foundBase_.exchange(nullptr)) {
            adopt(found, foundStride_.load());
            if (base_ != nullptr) {
                protocol.setExternalTransport(true);
            }
        } else if (!scanning_.load() && now >= nextDiscovery_) {
            nextDiscovery_ = now + kDiscoveryInterval;
            startDiscovery();
        }
        return;
    }

    std::vector<std::int64_t> header;
    if (!readSlots(1, kMemHeaderSlots, header)) {
        lose("read failed", protocol);
        return;
    }
    if (header[0] != kMemMagic + 1 || header[3] != kMemMagic + 4) {
        char text[200];
        std::snprintf(text, sizeof(text), "magic gone: slots 1..7 = %llx %llx %llx %llx %llx %llx %llx",
                      static_cast<unsigned long long>(header[0]), static_cast<unsigned long long>(header[1]),
                      static_cast<unsigned long long>(header[2]), static_cast<unsigned long long>(header[3]),
                      static_cast<unsigned long long>(header[4]), static_cast<unsigned long long>(header[5]),
                      static_cast<unsigned long long>(header[6]));
        lose(text, protocol);
        return;
    }
    // A live table's heartbeat moves soon after adoption; a stale copy's never does. Later pauses
    // (loading screens freeze Lua for many seconds) are normal and do not drop the table.
    if (header[kSlotBeat - 1] != lastBeat_) {
        lastBeat_ = header[kSlotBeat - 1];
        if (!verified_) {
            verified_ = true;
            diagLog("mem bridge: Lua heartbeat confirmed");
        }
    } else if (!verified_ && now - lastBeatChange_ > kBeatTimeout) {
        lose("no heartbeat after adoption", protocol);
        return;
    }

    // Lua -> DLL
    const std::int64_t outHead = header[kSlotOutHead - 1];
    if (outHead - outTail_ > static_cast<std::int64_t>(kMemRingSlots) || outHead < outTail_) {
        lose("corrupt Lua ring", protocol);
        return;
    }
    if (outHead > outTail_) {
        std::string text;
        std::vector<std::int64_t> slots;
        for (std::int64_t s = outTail_; s < outHead;) {
            const std::size_t ring = static_cast<std::size_t>(s % static_cast<std::int64_t>(kMemRingSlots));
            const std::size_t run = std::min<std::size_t>(kMemRingSlots - ring, static_cast<std::size_t>(outHead - s));
            if (!readSlots(kOutData + ring, run, slots)) {
                lose("read failed", protocol);
                return;
            }
            for (const std::int64_t v : slots) {
                text.append(reinterpret_cast<const char*>(&v), 8);
            }
            s += static_cast<std::int64_t>(run);
        }
        outTail_ = outHead;
        writeSlots(kSlotOutTail, &outTail_, 1);
        rxPartial_ += text;
        const std::size_t cut = rxPartial_.rfind('\n');
        if (cut != std::string::npos) {
            protocol.ingestFromLua(std::string_view(rxPartial_).substr(0, cut + 1), deliver, now);
            rxPartial_.erase(0, cut + 1);
        }
        if (rxPartial_.size() > (1u << 20)) {
            rxPartial_.clear(); // a line that never ends
        }
    }

    // DLL -> Lua
    txBacklog_ += protocol.takeForLua();
    if (txBacklog_.empty()) {
        return;
    }
    const std::int64_t inTail = header[kSlotInTail - 1];
    const std::int64_t freeSlots = static_cast<std::int64_t>(kMemRingSlots) - (inHead_ - inTail);
    if (freeSlots <= 0) {
        return;
    }
    // Pad only a complete backlog (it always ends with '\n'); a partial write is cut at 8 bytes.
    std::size_t bytes = std::min<std::size_t>(txBacklog_.size(), static_cast<std::size_t>(freeSlots) * 8);
    if (bytes == txBacklog_.size()) {
        txBacklog_.append((8 - txBacklog_.size() % 8) % 8, '\n');
        bytes = txBacklog_.size();
        if (bytes > static_cast<std::size_t>(freeSlots) * 8) {
            bytes -= 8;
        }
    } else {
        bytes -= bytes % 8;
    }
    std::vector<std::int64_t> values(bytes / 8);
    std::memcpy(values.data(), txBacklog_.data(), bytes);
    std::size_t written = 0;
    while (written < values.size()) {
        const std::size_t ring = static_cast<std::size_t>((inHead_ + static_cast<std::int64_t>(written)) %
                                                          static_cast<std::int64_t>(kMemRingSlots));
        const std::size_t run = std::min(kMemRingSlots - ring, values.size() - written);
        if (!writeSlots(kInData + ring, values.data() + written, run)) {
            lose("write failed", protocol);
            return;
        }
        written += run;
    }
    inHead_ += static_cast<std::int64_t>(values.size());
    writeSlots(kSlotInHead, &inHead_, 1); // published after the data
    txBacklog_.erase(0, bytes);
}

} // namespace pz2
