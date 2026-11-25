#pragma once

#include "spsc_queue.hpp"
#include "steam_p2p.hpp"

#include <chrono>
#include <cstdint>
#include <deque>
#include <filesystem>
#include <functional>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

namespace pz2 {

// Lua <-> DLL bridge over files (docs/LUA_API_MAP.md §10): the only Lua I/O the decompiled game code
// proves is api.debug.WriteStringToFile / ReadStringFromFile. Lua can neither delete files nor pack
// binary, so the DLL owns cleanup and the binary codec.
//
// Directory: <game exe dir>\PZ2Coop\  (bridge.txt is a beacon Lua probes to find its path prefix)
//
// Lua -> DLL   out_<n>.txt  one message per line, last line "#end". The DLL deletes it once read.
//   {"cmd":"hello","sid":"<id>"}     Lua (re)started: resets the DLL -> Lua stream
//   {"cmd":"ack","n":"<n>"}          Lua consumed in_1..in_<n>; the DLL deletes them
//   {"cmd":...}                      host/join/leave/status/apply_begin/apply_end (see ipc_bridge.hpp)
//   <type> <file|-> <json>           packet. Fixed-size types are packed from flat JSON numbers
//                                    (16 cursor: cx cy cz px py pz yaw | 17 ledger: cash cc speed tod |
//                                     33 delete: h x y z r). Other types send <json>['\0'<file bytes>].
//                                    "2 <file> {}" streams a park save (SAVE_CHUNK_DATA + SAVE_LOAD_COMMIT).
//
// DLL -> Lua   in_<n>.txt   first line "sid <id>", then messages, last line "#end". Written atomically.
//   {"event":...}                    status events from the Steam thread
//   <type> <rxfile|-> <json>         packets from the peer; an attachment is saved as <rxfile>
//                                    ("3 rx_save.bin {}" = the host's park save is ready to load)
inline constexpr wchar_t kFileBridgeDirName[] = L"PZ2Coop";

struct LuaLine {
    std::uint8_t type = 0;
    std::string file; // empty when "-"
    std::string json;
};

// Pure codec pieces (unit-tested in selftest.cpp).
std::optional<double> jsonGetNumber(std::string_view json, std::string_view key);
bool isSafeFileName(std::string_view name);
std::optional<LuaLine> parseLuaLine(std::string_view line);
// [type][payload] for a fixed-size packet type, built from flat JSON numbers; nullopt if invalid.
std::optional<std::vector<std::uint8_t>> packFixed(PacketType type, std::string_view json);
// Flat JSON for a fixed-size payload; "" if the size is wrong or a value is not finite.
std::string unpackFixed(PacketType type, const std::uint8_t* payload, std::size_t size);

class FileBridge {
public:
    using Clock = std::chrono::steady_clock;
    // Same contract as IpcServer::deliver: text = control JSON, binary = [PacketType][payload].
    using Deliver = std::function<void(bool isText, std::string_view data)>;

    // Creates the directory, clears stale exchange files and writes the beacon.
    bool open(const std::filesystem::path& dir);
    bool isOpen() const { return !dir_.empty(); }
    // Lua is connected (sent hello and keeps writing at least every few seconds).
    bool alive() const { return !sid_.empty(); }

    // Reads Lua's files and flushes pending DLL -> Lua messages. Call often from the IPC thread.
    void poll(const Deliver& deliver, Clock::time_point now);
    // Queues a message from the Steam thread for Lua; also assembles incoming park saves.
    void forward(const NetMessage& msg);
    void writeStatus(std::string_view text);

    // Transport-neutral entry points (used by MemBridge): feed Lua's text lines in, take text for Lua out.
    void ingestFromLua(std::string_view lines, const Deliver& deliver, Clock::time_point now);
    std::string takeForLua();
    // While another transport carries the lines, no in_<n>.txt files are written.
    void setExternalTransport(bool on) { external_ = on; }

private:
    void readLuaFiles(const Deliver& deliver, Clock::time_point now);
    void handleLuaLine(std::string_view line, const Deliver& deliver);
    void sendSave(const Deliver& deliver, const std::string& file);
    void start(std::string sid);
    void ack(std::uint32_t upTo);
    void dropClient();
    void flush();
    void receiveSaveChunk(const std::uint8_t* p, std::size_t n);
    bool finishSave();
    void removeInFiles();

    std::filesystem::path dir_;
    std::string sid_;
    Clock::time_point lastLua_{};
    Clock::time_point nextScan_{};
    Clock::time_point nextFlush_{};
    std::uint32_t inSeq_ = 0;
    std::deque<std::uint32_t> unacked_;
    std::string pending_;
    std::uint32_t rxAttach_ = 0;
    bool external_ = false;

    std::uint32_t saveNext_ = 0;
    std::uint32_t saveCount_ = 0;
    std::uint64_t saveBytes_ = 0;
    bool saveOk_ = false;
};

} // namespace pz2
