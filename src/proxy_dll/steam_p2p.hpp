#pragma once

#include <cstdint>
#include <optional>
#include <string>
#include <string_view>

namespace pz2 {

// ---------------------------------------------------------------------------------------------
// Wire protocol (docs/NETWORK_PROTOCOL.md)
// ---------------------------------------------------------------------------------------------
#pragma pack(push, 1)
enum class PacketType : std::uint8_t {
    HANDSHAKE_HELLO = 0x01,
    SAVE_CHUNK_DATA = 0x02,
    SAVE_LOAD_COMMIT = 0x03,
    CURSOR_TRANSFORM_20HZ = 0x10,
    LEDGER_SYNC_1HZ = 0x11,
    PRESENCE_AVATAR = 0x12, // JSON avatar look (guest prefab + multipart props), once per connection
    ACTION_PLACE_OBJECT = 0x20,
    ACTION_DELETE_SPATIAL = 0x21,
    ACTION_PATH_STAMP = 0x22,
    ACTION_TERRAIN_STROKE = 0x23,
    ACTION_ANIMAL_EVENT = 0x30,
    ANIMAL_WAYPOINT_10HZ = 0x31,
};

struct PacketHeader {
    std::uint32_t magic;        // kPacketMagic
    std::uint8_t version;       // kProtocolVersion
    PacketType type;
    std::uint16_t flags;        // bit 0: LZ4 compressed
    std::uint32_t sequence;     // monotonic per sender
    std::uint32_t payload_size; // bytes following the header
};

struct CursorTransformPayload {
    float cam_pos[3];
    float cursor_pos[3];
    float cursor_yaw;
    float mode; // 0 = flying build camera, 1 = walking first person, 2 = walking third person
};

struct LedgerSyncPayload {
    std::int64_t cash_cents;
    std::int32_t conservation_credits;
    std::uint32_t game_speed_state;
    float time_of_day;
};
#pragma pack(pop)

static_assert(sizeof(PacketHeader) == 16);
static_assert(sizeof(CursorTransformPayload) == 32);
static_assert(sizeof(LedgerSyncPayload) == 20);

inline constexpr std::uint32_t kPacketMagic = 0x505A3243; // 'PZ2C'
// v2: ACTION_DELETE_SPATIAL carries JSON (part name, peer-owned flag) instead of a fixed struct.
inline constexpr std::uint8_t kProtocolVersion = 0x02;
inline constexpr std::uint16_t kFlagLz4 = 0x0001;
inline constexpr std::uint32_t kMaxPacketSize = 512 * 1024; // Steam's max reliable message size
inline constexpr std::uint32_t kMaxPayloadSize = kMaxPacketSize - sizeof(PacketHeader);

constexpr bool isKnownPacketType(std::uint8_t t) {
    switch (static_cast<PacketType>(t)) {
    case PacketType::HANDSHAKE_HELLO:
    case PacketType::SAVE_CHUNK_DATA:
    case PacketType::SAVE_LOAD_COMMIT:
    case PacketType::CURSOR_TRANSFORM_20HZ:
    case PacketType::LEDGER_SYNC_1HZ:
    case PacketType::PRESENCE_AVATAR:
    case PacketType::ACTION_PLACE_OBJECT:
    case PacketType::ACTION_DELETE_SPATIAL:
    case PacketType::ACTION_PATH_STAMP:
    case PacketType::ACTION_TERRAIN_STROKE:
    case PacketType::ACTION_ANIMAL_EVENT:
    case PacketType::ANIMAL_WAYPOINT_10HZ:
        return true;
    }
    return false;
}

// Channel 1 (unreliable, coalesced to 20 Hz). Everything else is Channel 0 (reliable).
constexpr bool isUnreliable(PacketType t) {
    return t == PacketType::CURSOR_TRANSFORM_20HZ || t == PacketType::LEDGER_SYNC_1HZ ||
           t == PacketType::ANIMAL_WAYPOINT_10HZ;
}

// Only the host may originate these (host-authoritative save + ledger).
constexpr bool isHostOnly(PacketType t) {
    return t == PacketType::SAVE_CHUNK_DATA || t == PacketType::SAVE_LOAD_COMMIT || t == PacketType::LEDGER_SYNC_1HZ;
}

// Player actions: dropped on the way out while g_IsApplyingRemoteAction is set.
constexpr bool isEchoGuarded(PacketType t) { return static_cast<std::uint8_t>(t) >= 0x20; }

// 0 = variable-size payload.
constexpr std::uint32_t fixedPayloadSize(PacketType t) {
    switch (t) {
    case PacketType::CURSOR_TRANSFORM_20HZ: return sizeof(CursorTransformPayload);
    case PacketType::LEDGER_SYNC_1HZ: return sizeof(LedgerSyncPayload);
    default: return 0;
    }
}

// ---------------------------------------------------------------------------------------------
// Room codes: lobby CSteamID = 0x01860000'xxxxxxxx; the low 32 bits become 6 Base62 chars.
// ---------------------------------------------------------------------------------------------
inline constexpr std::uint64_t kLobbyIdPrefix = 0x0186000000000000ULL;

// Returns "" if the lobby id doesn't carry the expected prefix.
std::string encodeRoomCode(std::uint64_t lobbyId);
// Accepts "abc123" or "PZ-abc123". Case-sensitive (Base62).
std::optional<std::uint64_t> decodeRoomCode(std::string_view code);

// Minimal extractor for "key":"value" string fields in the small control JSON the UI sends.
// ponytail: no escape handling or nesting; swap in a real JSON parser if commands grow complex.
std::string jsonGetString(std::string_view json, std::string_view key);

// JSON string literal (with quotes) for untrusted text such as Steam persona names: escapes '"' and
// '\', blanks control bytes, caps at ~64 bytes, cutting only between UTF-8 characters.
std::string jsonQuote(const char* text);

// Standard base64 (RFC 4648, with '=' padding).
std::string base64Encode(const std::uint8_t* data, std::size_t size);

void debugLog(const char* message);

// Starts the Steam networking thread (polls steam_api64.dll until SteamAPI is initialised).
void startSteamP2P();

} // namespace pz2
