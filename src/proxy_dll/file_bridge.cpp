#include "file_bridge.hpp"

#include "diag.hpp"

#include <algorithm>
#include <charconv>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <limits>
#include <system_error>
#include <utility>

namespace pz2 {

namespace fs = std::filesystem;

namespace {

constexpr std::size_t kSaveChunk = 256 * 1024;
constexpr std::uintmax_t kMaxSaveFile = 512ull * 1024 * 1024;
constexpr std::uintmax_t kMaxLuaFile = 16ull * 1024 * 1024;
constexpr std::uint32_t kMaxSaveChunks = static_cast<std::uint32_t>(kMaxSaveFile / kSaveChunk) + 1;
constexpr std::size_t kMaxUnacked = 2000;
constexpr std::uint32_t kRxAttachSlots = 64;
constexpr auto kLuaTimeout = std::chrono::seconds(10);
constexpr auto kIncompleteGrace = std::chrono::seconds(5);
constexpr auto kScanInterval = std::chrono::milliseconds(10);
constexpr auto kFlushInterval = std::chrono::milliseconds(20);
constexpr char kSaveName[] = "rx_save.bin";
constexpr char kSavePart[] = "rx_save.part";
constexpr char kEndMarker[] = "#end";

bool readFile(const fs::path& path, std::uintmax_t cap, std::string& out) {
    std::error_code ec;
    const auto size = fs::file_size(path, ec);
    if (ec || size > cap) {
        return false;
    }
    std::ifstream in(path, std::ios::binary);
    if (!in) {
        return false;
    }
    out.resize(static_cast<std::size_t>(size));
    in.read(out.data(), static_cast<std::streamsize>(out.size()));
    return static_cast<std::uintmax_t>(in.gcount()) == size;
}

// Readers never see a half-written file: write a temp file, then rename over the target.
bool writeFileAtomic(const fs::path& path, std::string_view data) {
    fs::path tmp = path;
    tmp += L".tmp";
    {
        std::ofstream out(tmp, std::ios::binary | std::ios::trunc);
        if (!out) {
            return false;
        }
        out.write(data.data(), static_cast<std::streamsize>(data.size()));
        if (!out) {
            return false;
        }
    }
    std::error_code ec;
    fs::rename(tmp, path, ec);
    return !ec;
}

// One message per line; valid JSON never needs a raw CR/LF, so they are blanked.
void appendLine(std::string& buffer, std::string_view line) {
    for (const char c : line) {
        buffer.push_back(c == '\n' || c == '\r' ? ' ' : c);
    }
    buffer.push_back('\n');
}

template <class T>
void put(std::vector<std::uint8_t>& out, const T& value) {
    const std::size_t at = out.size();
    out.resize(at + sizeof(T));
    std::memcpy(out.data() + at, &value, sizeof(T));
}

template <class T>
T get(const std::uint8_t* p) {
    T value{};
    std::memcpy(&value, p, sizeof(T));
    return value;
}

// "out_12.txt" -> 12
std::optional<std::uint32_t> parseSeq(const std::wstring& name, std::wstring_view prefix) {
    if (!name.starts_with(prefix) || !name.ends_with(L".txt")) {
        return std::nullopt;
    }
    const std::wstring_view digits(name.data() + prefix.size(), name.size() - prefix.size() - 4);
    if (digits.empty() || digits.size() > 9) {
        return std::nullopt;
    }
    std::uint32_t value = 0;
    for (const wchar_t c : digits) {
        if (c < L'0' || c > L'9') {
            return std::nullopt;
        }
        value = value * 10 + static_cast<std::uint32_t>(c - L'0');
    }
    return value;
}

bool inRange(double v, double lo, double hi) { return v >= lo && v <= hi; }

std::string_view asView(const std::vector<std::uint8_t>& v) {
    return {reinterpret_cast<const char*>(v.data()), v.size()};
}

} // namespace

std::optional<double> jsonGetNumber(std::string_view json, std::string_view key) {
    const std::string needle = "\"" + std::string(key) + "\"";
    std::size_t p = json.find(needle);
    if (p == std::string_view::npos) {
        return std::nullopt;
    }
    p += needle.size();
    const auto skipSpace = [&] {
        while (p < json.size() && (json[p] == ' ' || json[p] == '\t' || json[p] == '\r' || json[p] == '\n')) {
            ++p;
        }
    };
    skipSpace();
    if (p >= json.size() || json[p] != ':') {
        return std::nullopt;
    }
    ++p;
    skipSpace();
    double value = 0;
    const auto [end, ec] = std::from_chars(json.data() + p, json.data() + json.size(), value);
    if (ec != std::errc{} || end == json.data() + p || !std::isfinite(value)) {
        return std::nullopt;
    }
    return value;
}

bool isSafeFileName(std::string_view name) {
    if (name.empty() || name.size() > 64 || name[0] == '.') {
        return false;
    }
    return std::all_of(name.begin(), name.end(), [](char c) {
        return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || c == '-' ||
               c == '.';
    });
}

std::optional<LuaLine> parseLuaLine(std::string_view line) {
    const std::size_t sp1 = line.find(' ');
    if (sp1 == std::string_view::npos) {
        return std::nullopt;
    }
    const std::size_t sp2 = line.find(' ', sp1 + 1);
    if (sp2 == std::string_view::npos) {
        return std::nullopt;
    }
    unsigned type = 0;
    const auto [end, ec] = std::from_chars(line.data(), line.data() + sp1, type);
    if (ec != std::errc{} || end != line.data() + sp1 || type > 255 ||
        !isKnownPacketType(static_cast<std::uint8_t>(type))) {
        return std::nullopt;
    }
    LuaLine out;
    out.type = static_cast<std::uint8_t>(type);
    const std::string_view file = line.substr(sp1 + 1, sp2 - sp1 - 1);
    if (file != "-") {
        if (!isSafeFileName(file)) {
            return std::nullopt;
        }
        out.file = std::string(file);
    }
    out.json = std::string(line.substr(sp2 + 1));
    if (out.json.empty() || out.json[0] != '{') {
        return std::nullopt;
    }
    return out;
}

std::optional<std::vector<std::uint8_t>> packFixed(PacketType type, std::string_view json) {
    const auto num = [&](const char* key) { return jsonGetNumber(json, key); };
    std::vector<std::uint8_t> out{static_cast<std::uint8_t>(type)};
    switch (type) {
    case PacketType::CURSOR_TRANSFORM_20HZ: {
        constexpr const char* keys[] = {"cx", "cy", "cz", "px", "py", "pz", "yaw", "m"};
        float values[8] = {};
        for (std::size_t i = 0; i < 8; ++i) {
            const auto v = num(keys[i]);
            if (!v || !inRange(*v, -1e7, 1e7)) {
                return std::nullopt;
            }
            values[i] = static_cast<float>(*v);
        }
        if (values[7] < 0 || values[7] > 2) {
            return std::nullopt;
        }
        CursorTransformPayload payload{};
        static_assert(sizeof(values) == sizeof(payload));
        std::memcpy(&payload, values, sizeof(payload));
        put(out, payload);
        return out;
    }
    case PacketType::LEDGER_SYNC_1HZ: {
        const auto cash = num("cash");
        const auto cc = num("cc");
        const auto speed = num("speed");
        const auto tod = num("tod");
        if (!cash || !cc || !speed || !tod || !inRange(*cash, -9e15, 9e15) || !inRange(*cc, -2147483648.0, 2147483647.0) ||
            !inRange(*speed, 0, 3) || !inRange(*tod, 0, 24)) {
            return std::nullopt;
        }
        const LedgerSyncPayload payload{std::llround(*cash), static_cast<std::int32_t>(std::lround(*cc)),
                                        static_cast<std::uint32_t>(std::lround(*speed)), static_cast<float>(*tod)};
        put(out, payload);
        return out;
    }
    default:
        return std::nullopt;
    }
}

std::string unpackFixed(PacketType type, const std::uint8_t* payload, std::size_t size) {
    if (size != fixedPayloadSize(type) || size == 0) {
        return {};
    }
    char buf[320] = {};
    switch (type) {
    case PacketType::CURSOR_TRANSFORM_20HZ: {
        const auto c = get<CursorTransformPayload>(payload);
        const float values[8] = {c.cam_pos[0], c.cam_pos[1], c.cam_pos[2], c.cursor_pos[0],
                                 c.cursor_pos[1], c.cursor_pos[2], c.cursor_yaw, c.mode};
        for (const float v : values) {
            if (!std::isfinite(v)) {
                return {};
            }
        }
        if (values[7] < 0 || values[7] > 2) {
            return {};
        }
        std::snprintf(buf, sizeof(buf),
                      R"({"cx":%.9g,"cy":%.9g,"cz":%.9g,"px":%.9g,"py":%.9g,"pz":%.9g,"yaw":%.9g,"m":%.9g})",
                      double{values[0]}, double{values[1]}, double{values[2]}, double{values[3]}, double{values[4]},
                      double{values[5]}, double{values[6]}, double{values[7]});
        return buf;
    }
    case PacketType::LEDGER_SYNC_1HZ: {
        const auto l = get<LedgerSyncPayload>(payload);
        if (!std::isfinite(l.time_of_day)) {
            return {};
        }
        std::snprintf(buf, sizeof(buf), R"({"cash":%lld,"cc":%d,"speed":%u,"tod":%.9g})",
                      static_cast<long long>(l.cash_cents), l.conservation_credits, l.game_speed_state,
                      double{l.time_of_day});
        return buf;
    }
    default:
        return {};
    }
}

// ---------------------------------------------------------------------------------------------
// FileBridge
// ---------------------------------------------------------------------------------------------
bool FileBridge::open(const fs::path& dir) {
    std::error_code ec;
    fs::create_directories(dir, ec);
    if (!fs::is_directory(dir, ec)) {
        return false;
    }
    std::vector<fs::path> stale;
    for (auto it = fs::directory_iterator(dir, ec); !ec && it != fs::directory_iterator(); it.increment(ec)) {
        const std::wstring name = it->path().filename().wstring();
        if (name.starts_with(L"in_") || name.starts_with(L"out_") || name.starts_with(L"rx_") || name.ends_with(L".tmp")) {
            stale.push_back(it->path());
        }
    }
    for (const auto& path : stale) {
        fs::remove(path, ec);
    }
    if (!writeFileAtomic(dir / L"bridge.txt", "PZ2Coop file bridge v1\n")) {
        return false;
    }
    dir_ = dir;
    return true;
}

void FileBridge::poll(const Deliver& deliver, Clock::time_point now) {
    if (dir_.empty()) {
        return;
    }
    if (now >= nextScan_) {
        nextScan_ = now + kScanInterval;
        readLuaFiles(deliver, now);
    }
    // Only for the file transport: the memory bridge has its own liveness check (magic + heartbeat) that
    // survives loading screens, which freeze Lua for longer than kLuaTimeout. Dropping the client there
    // silently discarded every command and event after a park load (co-op screen stuck on "Connecting").
    if (alive() && !external_ && now - lastLua_ > kLuaTimeout) {
        debugLog("file bridge: Lua stopped writing; dropping it until the next hello");
        dropClient();
    }
    if (alive() && !external_ && !pending_.empty() && now >= nextFlush_) {
        flush();
        nextFlush_ = now + kFlushInterval;
    }
}

void FileBridge::readLuaFiles(const Deliver& deliver, Clock::time_point now) {
    std::vector<std::pair<std::uint32_t, fs::path>> files;
    std::error_code ec;
    for (auto it = fs::directory_iterator(dir_, ec); !ec && it != fs::directory_iterator(); it.increment(ec)) {
        if (const auto seq = parseSeq(it->path().filename().wstring(), L"out_")) {
            files.emplace_back(*seq, it->path());
        }
    }
    std::sort(files.begin(), files.end());
    for (const auto& [seq, path] : files) {
        std::string data;
        if (!readFile(path, kMaxLuaFile, data)) {
            if (fs::file_size(path, ec) > kMaxLuaFile && !ec) {
                fs::remove(path, ec);
                debugLog("file bridge: oversized Lua file dropped");
                continue;
            }
            break; // still being written / locked: keep order, retry next scan
        }
        std::string_view body(data);
        while (!body.empty() && (body.back() == '\n' || body.back() == '\r' || body.back() == ' ')) {
            body.remove_suffix(1);
        }
        if (!body.ends_with(kEndMarker)) {
            const auto written = fs::last_write_time(path, ec);
            if (!ec && fs::file_time_type::clock::now() - written > kIncompleteGrace) {
                fs::remove(path, ec); // a writer that died mid-file
                continue;
            }
            break;
        }
        fs::remove(path, ec);
        body.remove_suffix(sizeof(kEndMarker) - 1);
        ingestFromLua(body, deliver, now);
    }
}

void FileBridge::ingestFromLua(std::string_view lines, const Deliver& deliver, Clock::time_point now) {
    lastLua_ = now;
    while (!lines.empty()) {
        const std::size_t nl = lines.find('\n');
        std::string_view line = lines.substr(0, nl);
        lines = nl == std::string_view::npos ? std::string_view{} : lines.substr(nl + 1);
        if (!line.empty() && line.back() == '\r') {
            line.remove_suffix(1);
        }
        handleLuaLine(line, deliver);
    }
}

std::string FileBridge::takeForLua() {
    if (!alive()) {
        return {};
    }
    return std::exchange(pending_, std::string());
}

void FileBridge::handleLuaLine(std::string_view line, const Deliver& deliver) {
    if (line.empty()) {
        return;
    }
    if (line[0] == '{') {
        const std::string cmd = jsonGetString(line, "cmd");
        if (cmd == "hello") {
            start(jsonGetString(line, "sid"));
            return;
        }
        if (cmd == "diag") { // Lua's only log channel in retail
            diagLog("lua: " + jsonGetString(line, "msg"));
            return;
        }
        if (cmd == "ack") {
            const std::string n = jsonGetString(line, "n");
            std::uint32_t upTo = 0;
            const auto [end, ec] = std::from_chars(n.data(), n.data() + n.size(), upTo);
            if (ec == std::errc{} && end == n.data() + n.size()) {
                ack(upTo);
            }
            return;
        }
        if (alive()) {
            deliver(true, line);
        } else {
            diagLog("file bridge: dropped Lua command (no session): " + std::string(line.substr(0, 120)));
        }
        return;
    }
    if (!alive()) {
        return;
    }
    const auto parsed = parseLuaLine(line);
    if (!parsed) {
        debugLog("file bridge: malformed Lua line dropped");
        return;
    }
    const auto type = static_cast<PacketType>(parsed->type);
    if (fixedPayloadSize(type) != 0) {
        if (const auto packet = packFixed(type, parsed->json)) {
            deliver(false, asView(*packet));
        }
        return;
    }
    if (type == PacketType::SAVE_CHUNK_DATA) {
        if (!parsed->file.empty()) {
            sendSave(deliver, parsed->file);
        }
        return;
    }
    std::string payload(1, static_cast<char>(parsed->type));
    payload += parsed->json;
    if (!parsed->file.empty()) {
        std::string attachment;
        if (!readFile(dir_ / parsed->file, kMaxPayloadSize, attachment)) {
            debugLog("file bridge: attachment missing or too large");
            return;
        }
        payload.push_back('\0');
        payload += attachment;
    }
    if (payload.size() > 1 + std::size_t{kMaxPayloadSize}) {
        debugLog("file bridge: packet too large");
        return;
    }
    deliver(false, payload);
}

void FileBridge::sendSave(const Deliver& deliver, const std::string& file) {
    std::string data;
    if (!readFile(dir_ / file, kMaxSaveFile, data)) {
        diagLog("join: park save for the guest missing or too large");
        return;
    }
    const auto count = static_cast<std::uint32_t>(std::max<std::size_t>(1, (data.size() + kSaveChunk - 1) / kSaveChunk));
    diagLog("join: sending park save, " + std::to_string(data.size()) + " bytes in " + std::to_string(count) + " chunks");
    for (std::uint32_t i = 0; i < count; ++i) {
        const std::size_t offset = std::size_t{i} * kSaveChunk;
        const std::size_t len = std::min(kSaveChunk, data.size() - offset);
        std::vector<std::uint8_t> packet{static_cast<std::uint8_t>(PacketType::SAVE_CHUNK_DATA)};
        put(packet, i);
        put(packet, count);
        packet.insert(packet.end(), data.begin() + static_cast<std::ptrdiff_t>(offset),
                      data.begin() + static_cast<std::ptrdiff_t>(offset + len));
        deliver(false, asView(packet));
    }
    deliver(false, std::string_view("\x03{}", 3));
}

void FileBridge::start(std::string sid) {
    if (!isSafeFileName(sid)) {
        return;
    }
    removeInFiles();
    sid_ = std::move(sid);
    inSeq_ = 0;
    pending_.clear();
    g_IsApplyingRemoteAction.store(false, std::memory_order_release);
    debugLog("file bridge: Lua connected");
}

void FileBridge::ack(std::uint32_t upTo) {
    std::error_code ec;
    while (!unacked_.empty() && unacked_.front() <= upTo) {
        fs::remove(dir_ / (L"in_" + std::to_wstring(unacked_.front()) + L".txt"), ec);
        unacked_.pop_front();
    }
}

void FileBridge::dropClient() {
    diagLog("file bridge: Lua session dropped");
    removeInFiles();
    sid_.clear();
    pending_.clear();
    g_IsApplyingRemoteAction.store(false, std::memory_order_release); // never leave the echo guard stuck
}

void FileBridge::removeInFiles() {
    std::error_code ec;
    for (const std::uint32_t seq : unacked_) {
        fs::remove(dir_ / (L"in_" + std::to_wstring(seq) + L".txt"), ec);
    }
    unacked_.clear();
}

void FileBridge::flush() {
    if (unacked_.size() >= kMaxUnacked) {
        debugLog("file bridge: Lua stopped acking; dropping it");
        dropClient();
        return;
    }
    const std::uint32_t seq = ++inSeq_;
    const std::string content = "sid " + sid_ + "\n" + pending_ + kEndMarker + "\n";
    if (writeFileAtomic(dir_ / (L"in_" + std::to_wstring(seq) + L".txt"), content)) {
        unacked_.push_back(seq);
        pending_.clear();
    } else {
        --inSeq_; // retry on the next flush
    }
}

void FileBridge::forward(const NetMessage& msg) {
    if (dir_.empty()) {
        return;
    }
    if (msg.kind == MsgKind::Json) {
        if (alive()) {
            appendLine(pending_, asView(msg.data));
        }
        return;
    }
    if (msg.data.empty()) {
        return;
    }
    const std::uint8_t typeByte = msg.data[0];
    const auto type = static_cast<PacketType>(typeByte);
    const std::uint8_t* payload = msg.data.data() + 1;
    const std::size_t size = msg.data.size() - 1;
    std::string line;
    switch (type) {
    case PacketType::SAVE_CHUNK_DATA:
        receiveSaveChunk(payload, size);
        return;
    case PacketType::SAVE_LOAD_COMMIT:
        if (!finishSave()) {
            diagLog("join: incomplete park save discarded");
            line = R"({"event":"error","code":"zoo_transfer_failed"})";
            break;
        }
        diagLog("join: park save received, " + std::to_string(saveBytes_) + " bytes");
        line = std::string("3 ") + kSaveName + " {}";
        break;
    case PacketType::HANDSHAKE_HELLO: {
        // C++ connect hello is 0 bytes ("1 - {}"); Lua sends JSON metadata (mode, scenario, diff, wild, ver).
        if (size == 0) {
            line = "1 - {}";
            break;
        }
        constexpr std::size_t kMaxHelloJson = 2048;
        if (size > kMaxHelloJson) {
            return;
        }
        const std::string_view body(reinterpret_cast<const char*>(payload), size);
        if (body[0] != '{' || body.back() != '}') {
            return;
        }
        for (const char c : body) {
            if (static_cast<unsigned char>(c) < 0x20) {
                return;
            }
        }
        line = "1 - " + std::string(body);
        break;
    }
    default:
        if (fixedPayloadSize(type) != 0) {
            const std::string json = unpackFixed(type, payload, size);
            if (json.empty()) {
                return;
            }
            line = std::to_string(typeByte) + " - " + json;
        } else {
            const std::string_view body(reinterpret_cast<const char*>(payload), size);
            const std::size_t split = body.find('\0');
            const std::string_view json = body.substr(0, split);
            if (json.empty() || json[0] != '{') {
                return;
            }
            std::string rxFile = "-";
            if (split != std::string_view::npos) {
                rxFile = "rx_" + std::to_string(rxAttach_++ % kRxAttachSlots) + ".bin";
                if (!writeFileAtomic(dir_ / rxFile, body.substr(split + 1))) {
                    return;
                }
            }
            line = std::to_string(typeByte) + " " + rxFile + " " + std::string(json);
        }
        break;
    }
    if (alive()) {
        appendLine(pending_, line);
    }
}

void FileBridge::receiveSaveChunk(const std::uint8_t* p, std::size_t n) {
    // Logged once per failed transfer; the commit then reports zoo_transfer_failed to the UI.
    const auto reject = [this](const char* why) {
        if (saveOk_) {
            diagLog(std::string("join: park save rejected at chunk ") + std::to_string(saveNext_) + ": " + why);
        }
        saveOk_ = false;
    };
    if (n < 8) {
        reject("short chunk");
        return;
    }
    const auto index = get<std::uint32_t>(p);
    const auto count = get<std::uint32_t>(p + 4);
    const fs::path part = dir_ / kSavePart;
    std::ios::openmode mode = std::ios::binary | std::ios::app;
    if (index == 0) {
        saveNext_ = 0;
        saveCount_ = count;
        saveBytes_ = 0;
        saveOk_ = count > 0 && count <= kMaxSaveChunks;
        mode = std::ios::binary | std::ios::trunc;
        diagLog("join: receiving park save, " + std::to_string(count) + " chunks");
    }
    if (!saveOk_ || index != saveNext_ || count != saveCount_ || saveBytes_ + (n - 8) > kMaxSaveFile) {
        reject("out of order or too large");
        return;
    }
    std::ofstream out(part, mode);
    out.write(reinterpret_cast<const char*>(p + 8), static_cast<std::streamsize>(n - 8));
    if (!out) {
        reject("disk write failed");
        return;
    }
    saveBytes_ += n - 8;
    ++saveNext_;
    // Lets the guest's Co-op screen show download progress instead of a bare spinner.
    if (alive()) {
        appendLine(pending_, R"({"event":"save_progress","got":)" + std::to_string(saveNext_) + R"(,"total":)" +
                                 std::to_string(saveCount_) + R"(,"bytes":)" + std::to_string(saveBytes_) + "}");
    }
}

bool FileBridge::finishSave() {
    const bool complete = saveOk_ && saveCount_ > 0 && saveNext_ == saveCount_;
    saveOk_ = false;
    saveCount_ = 0;
    saveNext_ = 0;
    if (!complete) {
        return false;
    }
    std::error_code ec;
    fs::rename(dir_ / kSavePart, dir_ / kSaveName, ec);
    return !ec;
}

void FileBridge::writeStatus(std::string_view text) {
    if (!dir_.empty()) {
        writeFileAtomic(dir_ / L"status.txt", text);
    }
}

} // namespace pz2
