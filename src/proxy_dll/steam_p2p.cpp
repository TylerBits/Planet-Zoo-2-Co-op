#include "steam_p2p.hpp"

#include "diag.hpp"
#include "lz4_codec.hpp"
#include "spsc_queue.hpp"

#include <windows.h>

#include <algorithm>
#include <array>
#include <charconv>
#include <chrono>
#include <cstddef>
#include <cstring>
#include <deque>
#include <mutex>
#include <optional>
#include <string>
#include <thread>
#include <type_traits>
#include <unordered_set>
#include <vector>

namespace pz2 {

namespace {
constexpr char kBase62[] = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";
constexpr std::size_t kRoomCodeLength = 6;
} // namespace

std::string encodeRoomCode(std::uint64_t lobbyId) {
    if ((lobbyId & 0xFFFFFFFF00000000ULL) != kLobbyIdPrefix) {
        return {};
    }
    auto value = static_cast<std::uint32_t>(lobbyId);
    std::string code(kRoomCodeLength, '0');
    for (std::size_t i = kRoomCodeLength; i-- > 0;) {
        code[i] = kBase62[value % 62];
        value /= 62;
    }
    return code;
}

std::optional<std::uint64_t> decodeRoomCode(std::string_view code) {
    if (code.size() == kRoomCodeLength + 3 && (code[0] == 'P' || code[0] == 'p') && (code[1] == 'Z' || code[1] == 'z') &&
        code[2] == '-') {
        code.remove_prefix(3);
    }
    if (code.size() != kRoomCodeLength) {
        return std::nullopt;
    }
    const std::string_view alphabet(kBase62, 62);
    std::uint64_t value = 0;
    for (const char c : code) {
        const std::size_t digit = alphabet.find(c);
        if (digit == std::string_view::npos) {
            return std::nullopt;
        }
        value = value * 62 + digit;
    }
    if (value > 0xFFFFFFFFULL) {
        return std::nullopt;
    }
    return kLobbyIdPrefix | value;
}

std::string jsonGetString(std::string_view json, std::string_view key) {
    const std::string needle = "\"" + std::string(key) + "\"";
    std::size_t p = json.find(needle);
    if (p == std::string_view::npos) {
        return {};
    }
    p += needle.size();
    const auto skipSpace = [&] {
        while (p < json.size() && (json[p] == ' ' || json[p] == '\t' || json[p] == '\r' || json[p] == '\n')) {
            ++p;
        }
    };
    skipSpace();
    if (p >= json.size() || json[p] != ':') {
        return {};
    }
    ++p;
    skipSpace();
    if (p >= json.size() || json[p] != '"') {
        return {};
    }
    ++p;
    const std::size_t end = json.find('"', p);
    if (end == std::string_view::npos) {
        return {};
    }
    return std::string(json.substr(p, end - p));
}

void debugLog(const char* message) {
    OutputDebugStringA("[PZ2Coop] ");
    OutputDebugStringA(message);
    OutputDebugStringA("\n");
}

// Steam persona names are user-controlled: quotes, backslashes and control bytes are escaped so a name
// can't break (or inject fields into) the JSON event. Capped at ~64 bytes, cut only between UTF-8
// characters (a character that starts before the cap is kept whole).
std::string base64Encode(const std::uint8_t* data, std::size_t size) {
    static constexpr char kTable[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    std::string out;
    out.reserve((size + 2) / 3 * 4);
    for (std::size_t i = 0; i < size; i += 3) {
        const std::uint32_t b0 = data[i];
        const std::uint32_t b1 = i + 1 < size ? data[i + 1] : 0;
        const std::uint32_t b2 = i + 2 < size ? data[i + 2] : 0;
        const std::uint32_t v = (b0 << 16) | (b1 << 8) | b2;
        out += kTable[(v >> 18) & 63];
        out += kTable[(v >> 12) & 63];
        out += i + 1 < size ? kTable[(v >> 6) & 63] : '=';
        out += i + 2 < size ? kTable[v & 63] : '=';
    }
    return out;
}

std::string jsonQuote(const char* text) {
    std::string out = "\"";
    std::size_t taken = 0;
    for (const char* p = text ? text : ""; *p != '\0'; ++p, ++taken) {
        const auto c = static_cast<unsigned char>(*p);
        if (taken >= 64 && (c & 0xC0) != 0x80) {
            break;
        }
        if (c == '"' || c == '\\') {
            out += '\\';
            out += static_cast<char>(c);
        } else if (c < 0x20) {
            out += ' ';
        } else {
            out += static_cast<char>(c);
        }
    }
    out += '"';
    return out;
}

namespace {

// ---------------------------------------------------------------------------------------------
// Minimal Steamworks flat-API ABI. Matches the steam_api64.dll shipped with Planet Zoo 2
// (exports SteamAPI_SteamMatchmaking_v009 / SteamNetworkingSockets_SteamAPI_v012 / SteamUtils_v010).
// Windows Steamworks structs use 8-byte packing, which is MSVC's default.
// ---------------------------------------------------------------------------------------------
namespace steam {
using HSteamUser = std::int32_t;
using SteamAPICall_t = std::uint64_t;
using HSteamNetConnection = std::uint32_t;
using HSteamListenSocket = std::uint32_t;

constexpr const char* kMatchmakingVersion = "SteamMatchMaking009";
constexpr const char* kSocketsVersion = "SteamNetworkingSockets012";
constexpr const char* kUtilsVersion = "SteamUtils010";

constexpr const char* kFriendsVersion = "SteamFriends018";
constexpr const char* kUserVersion = "SteamUser023";

constexpr std::int32_t kResultOK = 1;
constexpr std::int32_t kResultLimitExceeded = 25;
constexpr std::int32_t kLobbyTypeFriendsOnly = 1;
constexpr std::int32_t kLobbyTypePublic = 2;
constexpr int kFriendFlagImmediate = 4;
constexpr int kPersonaStateOffline = 0;
constexpr int kCallbackLobbyEnter = 504;   // k_iSteamMatchmakingCallbacks + 4
constexpr int kCallbackLobbyCreated = 513; // k_iSteamMatchmakingCallbacks + 13
constexpr std::uint32_t kChatRoomEnterSuccess = 1;
constexpr std::int32_t kIdentityTypeSteamID = 16;
constexpr std::int32_t kConfigCallbackConnectionStatusChanged = 201;
constexpr std::int32_t kConfigDataTypePtr = 5;
constexpr int kSendUnreliableNoNagle = 1;
constexpr int kSendReliable = 8;
constexpr std::int32_t kStateConnecting = 1;
constexpr std::int32_t kStateConnected = 3;
constexpr std::int32_t kStateClosedByPeer = 4;
constexpr std::int32_t kStateProblemDetectedLocally = 5;
constexpr int kEndReasonAppGeneric = 1000;
constexpr int kVirtualPort = 0;

#pragma pack(push, 1)
struct SteamNetworkingIPAddr {
    std::uint8_t ipv6[16];
    std::uint16_t port;
};
#pragma pack(pop)

struct SteamNetworkingIdentity {
    std::int32_t type;
    std::int32_t size;
    union {
        std::uint64_t steamID64;
        std::uint8_t reserved[128];
    } u;
};

struct SteamNetConnectionInfo {
    SteamNetworkingIdentity identityRemote;
    std::int64_t userData;
    HSteamListenSocket listenSocket;
    SteamNetworkingIPAddr addrRemote;
    std::uint16_t pad1;
    std::uint32_t popRemote;
    std::uint32_t popRelay;
    std::int32_t state;
    std::int32_t endReason;
    char endDebug[128];
    char connectionDescription[128];
    std::int32_t flags;
    std::uint32_t reserved[63];
};

struct SteamNetConnectionStatusChangedCallback {
    HSteamNetConnection conn;
    SteamNetConnectionInfo info;
    std::int32_t oldState;
};

// Leading fields of SteamNetworkingMessage_t; the rest is never touched (Steam owns the memory).
struct SteamNetworkingMessage {
    void* data;
    std::int32_t size;
};

struct SteamNetworkingConfigValue {
    std::int32_t value;
    std::int32_t dataType;
    union {
        std::int32_t i32;
        std::int64_t i64;
        float f;
        const char* s;
        void* p;
    } v;
};

struct LobbyCreated {
    std::int32_t result;
    std::uint64_t lobby;
};

struct LobbyEnter {
    std::uint64_t lobby;
    std::uint32_t chatPermissions;
    bool locked;
    std::uint32_t enterResponse;
};

static_assert(sizeof(SteamNetworkingIPAddr) == 18);
static_assert(sizeof(SteamNetworkingIdentity) == 136);
static_assert(offsetof(SteamNetConnectionInfo, state) == 176);
static_assert(offsetof(SteamNetConnectionStatusChangedCallback, info) == 8);
static_assert(offsetof(SteamNetConnectionStatusChangedCallback, info) + offsetof(SteamNetConnectionInfo, state) == 184);
static_assert(sizeof(SteamNetworkingConfigValue) == 16);
static_assert(sizeof(LobbyCreated) == 16);
static_assert(sizeof(LobbyEnter) == 24);

// ISteamFriends::GetFriendGamePlayed output (8-byte packing).
struct FriendGameInfo {
    std::uint64_t gameId; // CGameID: app id in the low 24 bits
    std::uint32_t gameIp;
    std::uint16_t gamePort;
    std::uint16_t queryPort;
    std::uint64_t lobby; // CSteamID of the lobby the friend is in, 0 if none
};
static_assert(sizeof(FriendGameInfo) == 24);
static_assert(offsetof(FriendGameInfo, lobby) == 16);

// SteamNetConnectionRealTimeStatus_t: only m_nPing (offset 4) is read; the buffer is oversized so a
// newer struct layout can never overrun it.
struct RealTimeStatus {
    std::int32_t state;
    std::int32_t ping;
    std::uint8_t rest[248];
};

using StatusChangedFn = void (*)(SteamNetConnectionStatusChangedCallback*);

struct Api {
    void* matchmaking = nullptr;
    void* sockets = nullptr;
    void* utils = nullptr;

    SteamAPICall_t (*CreateLobby)(void*, std::int32_t, int) = nullptr;
    SteamAPICall_t (*JoinLobby)(void*, std::uint64_t) = nullptr;
    void (*LeaveLobby)(void*, std::uint64_t) = nullptr;
    std::uint64_t (*GetLobbyOwner)(void*, std::uint64_t) = nullptr;
    int (*GetNumLobbyMembers)(void*, std::uint64_t) = nullptr;
    std::uint64_t (*GetLobbyMemberByIndex)(void*, std::uint64_t, int) = nullptr;

    bool (*IsAPICallCompleted)(void*, SteamAPICall_t, bool*) = nullptr;
    bool (*GetAPICallResult)(void*, SteamAPICall_t, void*, int, int, bool*) = nullptr;

    HSteamListenSocket (*CreateListenSocketP2P)(void*, int, int, const SteamNetworkingConfigValue*) = nullptr;
    HSteamNetConnection (*ConnectP2P)(void*, const SteamNetworkingIdentity*, int, int,
                                      const SteamNetworkingConfigValue*) = nullptr;
    std::int32_t (*AcceptConnection)(void*, HSteamNetConnection) = nullptr;
    bool (*CloseConnection)(void*, HSteamNetConnection, int, const char*, bool) = nullptr;
    bool (*CloseListenSocket)(void*, HSteamListenSocket) = nullptr;
    std::int32_t (*SendMessageToConnection)(void*, HSteamNetConnection, const void*, std::uint32_t, int,
                                            std::int64_t*) = nullptr;
    int (*ReceiveMessagesOnConnection)(void*, HSteamNetConnection, SteamNetworkingMessage**, int) = nullptr;
    void (*RunCallbacks)(void*) = nullptr;
    void (*ReleaseMessage)(SteamNetworkingMessage*) = nullptr;

    // Optional (co-op screen): missing ones only hide features, hosting/joining works without them.
    void* friends = nullptr;
    const char* (*GetPersonaName)(void*) = nullptr;
    int (*GetFriendCount)(void*, int) = nullptr;
    std::uint64_t (*GetFriendByIndex)(void*, int, int) = nullptr;
    const char* (*GetFriendPersonaName)(void*, std::uint64_t) = nullptr;
    int (*GetFriendPersonaState)(void*, std::uint64_t) = nullptr;
    bool (*GetFriendGamePlayed)(void*, std::uint64_t, FriendGameInfo*) = nullptr;
    bool (*InviteUserToLobby)(void*, std::uint64_t, std::uint64_t) = nullptr;
    bool (*SetLobbyType)(void*, std::uint64_t, std::int32_t) = nullptr;
    std::int32_t (*GetConnectionRealTimeStatus)(void*, HSteamNetConnection, RealTimeStatus*, int, void*) = nullptr;
    std::uint32_t (*GetAppID)(void*) = nullptr;
    void* user = nullptr;
    std::uint64_t (*GetSteamID)(void*) = nullptr;
    int (*GetSmallFriendAvatar)(void*, std::uint64_t) = nullptr;
    bool (*GetImageSize)(void*, int, std::uint32_t*, std::uint32_t*) = nullptr;
    bool (*GetImageRGBA)(void*, int, std::uint8_t*, int) = nullptr;

    bool hasAvatars() const { return friends && GetSmallFriendAvatar && GetImageSize && GetImageRGBA; }

    bool hasFriends() const {
        return friends && GetFriendCount && GetFriendByIndex && GetFriendPersonaName && GetFriendPersonaState &&
               GetFriendGamePlayed && GetAppID;
    }
};

// Returns false until steam_api64.dll is loaded AND the game has called SteamAPI_Init.
bool resolve(Api& api) {
    const HMODULE module = GetModuleHandleW(L"steam_api64.dll");
    if (module == nullptr) {
        return false;
    }
    const auto load = [module](auto& fn, const char* name) {
        fn = reinterpret_cast<std::remove_reference_t<decltype(fn)>>(GetProcAddress(module, name));
        return fn != nullptr;
    };

    HSteamUser (*getHSteamUser)() = nullptr;
    void* (*findOrCreateUserInterface)(HSteamUser, const char*) = nullptr;
    if (!load(getHSteamUser, "SteamAPI_GetHSteamUser") ||
        !load(findOrCreateUserInterface, "SteamInternal_FindOrCreateUserInterface")) {
        return false;
    }
    const HSteamUser user = getHSteamUser();
    if (user == 0) {
        return false;
    }
    api.matchmaking = findOrCreateUserInterface(user, kMatchmakingVersion);
    api.sockets = findOrCreateUserInterface(user, kSocketsVersion);
    api.utils = findOrCreateUserInterface(user, kUtilsVersion);
    api.friends = findOrCreateUserInterface(user, kFriendsVersion);
    load(api.GetPersonaName, "SteamAPI_ISteamFriends_GetPersonaName");
    load(api.GetFriendCount, "SteamAPI_ISteamFriends_GetFriendCount");
    load(api.GetFriendByIndex, "SteamAPI_ISteamFriends_GetFriendByIndex");
    load(api.GetFriendPersonaName, "SteamAPI_ISteamFriends_GetFriendPersonaName");
    load(api.GetFriendPersonaState, "SteamAPI_ISteamFriends_GetFriendPersonaState");
    load(api.GetFriendGamePlayed, "SteamAPI_ISteamFriends_GetFriendGamePlayed");
    load(api.InviteUserToLobby, "SteamAPI_ISteamMatchmaking_InviteUserToLobby");
    load(api.SetLobbyType, "SteamAPI_ISteamMatchmaking_SetLobbyType");
    load(api.GetConnectionRealTimeStatus, "SteamAPI_ISteamNetworkingSockets_GetConnectionRealTimeStatus");
    load(api.GetAppID, "SteamAPI_ISteamUtils_GetAppID");
    api.user = findOrCreateUserInterface(user, kUserVersion);
    load(api.GetSteamID, "SteamAPI_ISteamUser_GetSteamID");
    load(api.GetSmallFriendAvatar, "SteamAPI_ISteamFriends_GetSmallFriendAvatar");
    load(api.GetImageSize, "SteamAPI_ISteamUtils_GetImageSize");
    load(api.GetImageRGBA, "SteamAPI_ISteamUtils_GetImageRGBA");

    return api.matchmaking && api.sockets && api.utils &&
           load(api.CreateLobby, "SteamAPI_ISteamMatchmaking_CreateLobby") &&
           load(api.JoinLobby, "SteamAPI_ISteamMatchmaking_JoinLobby") &&
           load(api.LeaveLobby, "SteamAPI_ISteamMatchmaking_LeaveLobby") &&
           load(api.GetLobbyOwner, "SteamAPI_ISteamMatchmaking_GetLobbyOwner") &&
           load(api.GetNumLobbyMembers, "SteamAPI_ISteamMatchmaking_GetNumLobbyMembers") &&
           load(api.GetLobbyMemberByIndex, "SteamAPI_ISteamMatchmaking_GetLobbyMemberByIndex") &&
           load(api.IsAPICallCompleted, "SteamAPI_ISteamUtils_IsAPICallCompleted") &&
           load(api.GetAPICallResult, "SteamAPI_ISteamUtils_GetAPICallResult") &&
           load(api.CreateListenSocketP2P, "SteamAPI_ISteamNetworkingSockets_CreateListenSocketP2P") &&
           load(api.ConnectP2P, "SteamAPI_ISteamNetworkingSockets_ConnectP2P") &&
           load(api.AcceptConnection, "SteamAPI_ISteamNetworkingSockets_AcceptConnection") &&
           load(api.CloseConnection, "SteamAPI_ISteamNetworkingSockets_CloseConnection") &&
           load(api.CloseListenSocket, "SteamAPI_ISteamNetworkingSockets_CloseListenSocket") &&
           load(api.SendMessageToConnection, "SteamAPI_ISteamNetworkingSockets_SendMessageToConnection") &&
           load(api.ReceiveMessagesOnConnection, "SteamAPI_ISteamNetworkingSockets_ReceiveMessagesOnConnection") &&
           load(api.RunCallbacks, "SteamAPI_ISteamNetworkingSockets_RunCallbacks") &&
           load(api.ReleaseMessage, "SteamAPI_SteamNetworkingMessage_t_Release");
}
} // namespace steam

// Connection-status callbacks may fire on the game thread (SteamAPI_RunCallbacks) or on ours
// (ISteamNetworkingSockets::RunCallbacks), so they only record the event under a lock.
struct StatusEvent {
    steam::HSteamNetConnection conn;
    std::int32_t state;
    std::uint64_t remoteSteamId;
    std::int32_t endReason;
    std::string endDebug;
};
std::mutex g_statusMutex;
std::vector<StatusEvent> g_statusEvents;

void onConnectionStatusChanged(steam::SteamNetConnectionStatusChangedCallback* cb) {
    const std::uint64_t remote =
        cb->info.identityRemote.type == steam::kIdentityTypeSteamID ? cb->info.identityRemote.u.steamID64 : 0;
    const std::size_t debugLen = strnlen(cb->info.endDebug, sizeof(cb->info.endDebug));
    std::lock_guard lock(g_statusMutex);
    g_statusEvents.push_back({cb->conn, cb->info.state, remote, cb->info.endReason,
                              std::string(cb->info.endDebug, debugLen)});
}

steam::SteamNetworkingConfigValue statusCallbackOption() {
    steam::SteamNetworkingConfigValue option{};
    option.value = steam::kConfigCallbackConnectionStatusChanged;
    option.dataType = steam::kConfigDataTypePtr;
    option.v.p = reinterpret_cast<void*>(static_cast<steam::StatusChangedFn>(&onConnectionStatusChanged));
    return option;
}

void emit(const std::string& json) {
    // Session events go to diag.log (routine status/friends polls excepted) so a stuck UI can be traced.
    if (json.find(R"("event":"status")") == std::string::npos && json.find(R"("event":"friends")") == std::string::npos &&
        json.find(R"("event":"avatar")") == std::string::npos) {
        diagLog("steam: event " + json);
    }
    NetMessage msg{MsgKind::Json, std::vector<std::uint8_t>(json.begin(), json.end())};
    if (!g_IncomingQueue.push(std::move(msg))) {
        debugLog("incoming queue full, status event dropped");
    }
}

void emitError(const char* code) { emit(std::string(R"({"event":"error","code":")") + code + "\"}"); }

// Steam's matchmaking/utils interfaces are not thread-safe, and two host attempts crashed inside steamclient64
// (read of 0x300000151 in CreateListenSocketP2P). So our Steam calls and the game's per-frame
// SteamAPI_RunCallbacks never overlap: both hold this lock. Recursive in case a game callback re-enters.
std::recursive_mutex g_steamMutex;
using RunCallbacksFn = void (*)();
RunCallbacksFn g_gameRunCallbacks = nullptr;

void hkRunCallbacks() {
    std::lock_guard lock(g_steamMutex);
    g_gameRunCallbacks();
}

// Called once Steam is initialised, so the loader has long since bound the game's steam_api64 imports.
void hookGameRunCallbacks() {
    g_gameRunCallbacks = reinterpret_cast<RunCallbacksFn>(
        patchExeImport("steam_api64.dll", "SteamAPI_RunCallbacks", reinterpret_cast<void*>(&hkRunCallbacks)));
    diagLog(g_gameRunCallbacks != nullptr ? "steam: game's SteamAPI_RunCallbacks now shares our Steam lock"
                                          : "steam: SteamAPI_RunCallbacks import not found; Steam calls not serialised");
}

std::optional<std::uint64_t> parseU64(const std::string& text) {
    std::uint64_t value = 0;
    const auto [end, ec] = std::from_chars(text.data(), text.data() + text.size(), value);
    if (ec != std::errc{} || end != text.data() + text.size() || value == 0) {
        return std::nullopt;
    }
    return value;
}

using Clock = std::chrono::steady_clock;

class Session {
public:
    [[noreturn]] void run() {
        using namespace std::chrono_literals;
        auto nextResolve = Clock::now();
        auto nextUnreliableFlush = Clock::now();
        for (;;) {
            tick(Clock::now(), nextResolve, nextUnreliableFlush);
            std::this_thread::sleep_for(1ms); // outside the lock, so the game's frame never waits long
        }
    }

private:
    void tick(Clock::time_point now, Clock::time_point& nextResolve, Clock::time_point& nextUnreliableFlush) {
        using namespace std::chrono_literals;
        std::lock_guard lock(g_steamMutex);
        if (!ready_ && now >= nextResolve) {
            ready_ = steam::resolve(api_);
            nextResolve = now + 500ms;
            if (ready_) {
                debugLog("Steam interfaces resolved");
                hookGameRunCallbacks();
                emit(R"({"event":"steam_ready"})");
            }
        }
        if (ready_) {
            api_.RunCallbacks(api_.sockets);
            pollPendingCall();
            processStatusEvents(now);
            receive();
        }
        drainOutgoing();
        if (ready_) {
            flushReliable();
        }
        if (ready_ && now >= nextUnreliableFlush) {
            flushUnreliable(); // Channel 1 runs at 20 Hz: only the newest packet per type goes out.
            nextUnreliableFlush = now + 50ms;
        }
    }

    enum class Role { None, Host, Client };
    enum class Pending { None, CreateLobby, JoinLobby };

    // ---- control commands from the UI -------------------------------------------------------
    void handleCommand(std::string_view json) {
        const std::string cmd = jsonGetString(json, "cmd");
        if (cmd != "status" && cmd != "friends") {
            diagLog("steam: cmd " + std::string(json) + (ready_ ? "" : " (steam not ready)"));
        }
        if (cmd == "status") {
            emitStatus();
        } else if (cmd == "friends") {
            if (jsonGetString(json, "reset") == "1") {
                avatarsSent_.clear(); // a fresh Lua state has no cached pictures
            }
            emitFriends();
        } else if (cmd == "leave") {
            leave();
            emit(R"({"event":"left"})");
        } else if (cmd == "privacy") {
            const std::string type = jsonGetString(json, "type");
            if (type != "friends" && type != "public") {
                emitError("invalid_privacy");
                return;
            }
            lobbyType_ = type == "public" ? steam::kLobbyTypePublic : steam::kLobbyTypeFriendsOnly;
            if (ready_ && role_ == Role::Host && lobby_ != 0 && api_.SetLobbyType) {
                api_.SetLobbyType(api_.matchmaking, lobby_, lobbyType_);
            }
            emitStatus();
        } else if (cmd == "invite") {
            const auto friendId = parseU64(jsonGetString(json, "id"));
            if (!friendId || !ready_ || role_ != Role::Host || lobby_ == 0 || !api_.InviteUserToLobby ||
                !api_.InviteUserToLobby(api_.matchmaking, lobby_, *friendId)) {
                emitError("invite_failed");
                return;
            }
            emit(R"({"event":"invited","id":")" + std::to_string(*friendId) + "\"}");
        } else if (cmd == "host" || cmd == "join") {
            if (!ready_) {
                emitError("steam_not_ready");
            } else if (role_ != Role::None || pending_ != Pending::None) {
                emitError("already_in_session");
            } else if (cmd == "host") {
                startHost();
            } else if (const auto lobby = parseU64(jsonGetString(json, "lobby"))) {
                startJoinLobby(*lobby);
            } else {
                startJoin(jsonGetString(json, "code"));
            }
        } else {
            emitError("unknown_cmd");
        }
    }

    // Online Steam friends, Planet Zoo 2 players first; "lobby" is set when the friend sits in a lobby
    // of this game (= a co-op room), which the Join list offers directly.
    // ponytail: capped at 40 entries, no paging; add search if friend lists outgrow it.
    void emitFriends() {
        if (!ready_ || !api_.hasFriends()) {
            emit(R"({"event":"friends","available":false,"list":[]})");
            return;
        }
        const std::uint32_t appId = api_.GetAppID(api_.utils);
        struct Entry {
            std::uint64_t id;
            bool playing;
            std::uint64_t lobby;
            std::string name;
        };
        std::vector<Entry> list;
        const int count = api_.GetFriendCount(api_.friends, steam::kFriendFlagImmediate);
        for (int i = 0; i < count; ++i) {
            const std::uint64_t id = api_.GetFriendByIndex(api_.friends, i, steam::kFriendFlagImmediate);
            if (id == 0 || api_.GetFriendPersonaState(api_.friends, id) == steam::kPersonaStateOffline) {
                continue;
            }
            steam::FriendGameInfo game{};
            const bool inGame = api_.GetFriendGamePlayed(api_.friends, id, &game) &&
                                (game.gameId & 0xFFFFFFu) == appId;
            list.push_back({id, inGame, inGame ? game.lobby : 0, jsonQuote(api_.GetFriendPersonaName(api_.friends, id))});
        }
        std::stable_sort(list.begin(), list.end(), [](const Entry& a, const Entry& b) {
            return (a.lobby != 0) > (b.lobby != 0) || ((a.lobby != 0) == (b.lobby != 0) && a.playing > b.playing);
        });
        if (list.size() > 40) {
            list.resize(40);
        }
        std::string json = R"({"event":"friends","available":true,"list":[)";
        for (std::size_t i = 0; i < list.size(); ++i) {
            json += (i ? "," : "") + std::string(R"({"id":")") + std::to_string(list[i].id) + R"(","name":)" +
                    list[i].name + R"(,"playing":)" + (list[i].playing ? "true" : "false") + R"(,"lobby":")" +
                    (list[i].lobby ? std::to_string(list[i].lobby) : std::string()) + "\"}";
        }
        json += "]}";
        emit(json);
        std::vector<std::uint64_t> ids;
        if (api_.user && api_.GetSteamID) {
            ids.push_back(api_.GetSteamID(api_.user));
        }
        if (peer_ != 0) {
            ids.push_back(peer_);
        }
        for (const Entry& e : list) {
            ids.push_back(e.id);
        }
        emitAvatars(ids);
    }

    // Steam's 32x32 avatars as base64 RGB, each sent once (Lua caches them). Steam loads pictures
    // lazily: handle -1 means "not yet", so those ids are simply retried on the next friends poll.
    // ponytail: 8 per poll keeps one burst under ~40 KB of the 64 KB DLL->Lua ring.
    void emitAvatars(const std::vector<std::uint64_t>& ids) {
        if (!api_.hasAvatars()) {
            return;
        }
        int sent = 0;
        for (const std::uint64_t id : ids) {
            if (id == 0 || sent >= 8 || avatarsSent_.count(id) != 0) {
                continue;
            }
            const int image = api_.GetSmallFriendAvatar(api_.friends, id);
            std::uint32_t w = 0;
            std::uint32_t h = 0;
            if (image <= 0 || !api_.GetImageSize(api_.utils, image, &w, &h) || w == 0 || w != h || w > 64) {
                if (image == 0) {
                    avatarsSent_.insert(id); // no picture set: stop asking
                }
                continue;
            }
            std::vector<std::uint8_t> rgba(static_cast<std::size_t>(w) * h * 4);
            if (!api_.GetImageRGBA(api_.utils, image, rgba.data(), static_cast<int>(rgba.size()))) {
                continue;
            }
            std::vector<std::uint8_t> rgb;
            rgb.reserve(static_cast<std::size_t>(w) * h * 3);
            for (std::size_t p = 0; p < rgba.size(); p += 4) {
                rgb.insert(rgb.end(), {rgba[p], rgba[p + 1], rgba[p + 2]});
            }
            emit(R"({"event":"avatar","id":")" + std::to_string(id) + R"(","size":)" + std::to_string(w) +
                 R"(,"rgb":")" + base64Encode(rgb.data(), rgb.size()) + R"("})");
            avatarsSent_.insert(id);
            ++sent;
        }
    }

    void startHost() {
        call_ = api_.CreateLobby(api_.matchmaking, lobbyType_, 2);
        if (call_ == 0) {
            emitError("create_lobby_failed");
            return;
        }
        role_ = Role::Host;
        pending_ = Pending::CreateLobby;
    }

    void startJoin(const std::string& code) {
        const auto lobby = decodeRoomCode(code);
        if (!lobby) {
            emitError("invalid_room_code");
            return;
        }
        startJoinLobby(*lobby);
    }

    void startJoinLobby(std::uint64_t lobby) {
        call_ = api_.JoinLobby(api_.matchmaking, lobby);
        if (call_ == 0) {
            emitError("join_lobby_failed");
            return;
        }
        role_ = Role::Client;
        pending_ = Pending::JoinLobby;
    }

    void leave() {
        if (!ready_) {
            return;
        }
        if (conn_ != 0) {
            api_.CloseConnection(api_.sockets, conn_, steam::kEndReasonAppGeneric, "left session", true);
        }
        if (acceptConn_ != 0) {
            api_.CloseConnection(api_.sockets, acceptConn_, steam::kEndReasonAppGeneric, "left session", false);
        }
        if (listen_ != 0) {
            api_.CloseListenSocket(api_.sockets, listen_);
        }
        if (lobby_ != 0) {
            api_.LeaveLobby(api_.matchmaking, lobby_);
        }
        // A still-pending CreateLobby/JoinLobby is left running; pollPendingCall() leaves that
        // lobby as soon as it resolves because role_ is None by then.
        role_ = Role::None;
        lobby_ = 0;
        peer_ = 0;
        listen_ = 0;
        conn_ = 0;
        acceptConn_ = 0;
        connected_ = false;
        for (auto& p : pendingUnreliable_) {
            p.clear();
        }
        reliableBacklog_.clear();
    }

    void emitStatus() {
        const char* role = role_ == Role::Host ? "host" : role_ == Role::Client ? "client" : "none";
        std::string json = std::string(R"({"event":"status","steam_ready":)") + (ready_ ? "true" : "false") +
                           R"(,"role":")" + role + R"(","connected":)" + (connected_ ? "true" : "false") +
                           R"(,"pending":)" + (pending_ != Pending::None ? "true" : "false") + R"(,"privacy":")" +
                           (lobbyType_ == steam::kLobbyTypePublic ? "public" : "friends") + "\"";
        if (lobby_ != 0) {
            json += R"(,"room_code":")" + encodeRoomCode(lobby_) + "\"";
        }
        if (ready_ && api_.friends && api_.GetPersonaName) {
            json += R"(,"self_name":)" + jsonQuote(api_.GetPersonaName(api_.friends));
        }
        if (ready_ && api_.user && api_.GetSteamID) {
            json += R"(,"self_id":")" + std::to_string(api_.GetSteamID(api_.user)) + "\"";
        }
        if (peer_ != 0) {
            json += R"(,"partner_id":")" + std::to_string(peer_) + "\"";
        }
        if (ready_ && peer_ != 0 && api_.friends && api_.GetFriendPersonaName) {
            json += R"(,"partner_name":)" + jsonQuote(api_.GetFriendPersonaName(api_.friends, peer_));
        }
        steam::RealTimeStatus rt{};
        if (connected_ && api_.GetConnectionRealTimeStatus &&
            api_.GetConnectionRealTimeStatus(api_.sockets, conn_, &rt, 0, nullptr) == steam::kResultOK) {
            json += R"(,"ping":)" + std::to_string(rt.ping);
        }
        json += "}";
        emit(json);
    }

    // ---- async Steam calls (polled, so we don't depend on the game's callback dispatch) ------
    void pollPendingCall() {
        if (pending_ == Pending::None) {
            return;
        }
        bool failed = false;
        if (!api_.IsAPICallCompleted(api_.utils, call_, &failed)) {
            return;
        }
        const Pending which = pending_;
        pending_ = Pending::None;

        if (which == Pending::CreateLobby) {
            steam::LobbyCreated result{};
            const bool ok = api_.GetAPICallResult(api_.utils, call_, &result, sizeof(result),
                                                  steam::kCallbackLobbyCreated, &failed) &&
                            !failed && result.result == steam::kResultOK;
            if (role_ != Role::Host) { // "leave" arrived while the call was in flight
                if (ok) {
                    api_.LeaveLobby(api_.matchmaking, result.lobby);
                }
                return;
            }
            const std::string code = ok ? encodeRoomCode(result.lobby) : std::string();
            if (code.empty()) {
                diagLog("steam: CreateLobby failed: io_failure=" + std::to_string(failed) + " result=" +
                        std::to_string(result.result) + " lobby=" + std::to_string(result.lobby));
                if (ok) {
                    api_.LeaveLobby(api_.matchmaking, result.lobby);
                }
                role_ = Role::None;
                emitError("create_lobby_failed");
                return;
            }
            lobby_ = result.lobby;
            const auto option = statusCallbackOption();
            listen_ = api_.CreateListenSocketP2P(api_.sockets, steam::kVirtualPort, 1, &option);
            if (listen_ == 0) {
                leave();
                emitError("listen_socket_failed");
                return;
            }
            emit(R"({"event":"room_code","code":")" + code + "\"}");
            return;
        }

        steam::LobbyEnter result{};
        const bool ok = api_.GetAPICallResult(api_.utils, call_, &result, sizeof(result), steam::kCallbackLobbyEnter,
                                              &failed) &&
                        !failed && result.enterResponse == steam::kChatRoomEnterSuccess;
        if (role_ != Role::Client) {
            if (ok) {
                api_.LeaveLobby(api_.matchmaking, result.lobby);
            }
            return;
        }
        if (!ok) {
            role_ = Role::None;
            emitError("join_lobby_failed");
            return;
        }
        lobby_ = result.lobby;
        steam::SteamNetworkingIdentity host{};
        host.type = steam::kIdentityTypeSteamID;
        host.size = sizeof(std::uint64_t);
        host.u.steamID64 = api_.GetLobbyOwner(api_.matchmaking, lobby_);
        peer_ = host.u.steamID64;
        const auto option = statusCallbackOption();
        conn_ = api_.ConnectP2P(api_.sockets, &host, steam::kVirtualPort, 1, &option);
        if (conn_ == 0) {
            leave();
            emitError("connect_failed");
            return;
        }
        emit(R"({"event":"lobby_joined"})");
    }

    bool isLobbyMember(std::uint64_t steamId) const {
        if (steamId == 0 || lobby_ == 0) {
            return false;
        }
        const int count = api_.GetNumLobbyMembers(api_.matchmaking, lobby_);
        for (int i = 0; i < count; ++i) {
            if (api_.GetLobbyMemberByIndex(api_.matchmaking, lobby_, i) == steamId) {
                return true;
            }
        }
        return false;
    }

    void processStatusEvents(Clock::time_point now) {
        std::vector<StatusEvent> events;
        {
            std::lock_guard lock(g_statusMutex);
            events.swap(g_statusEvents);
        }
        for (const StatusEvent& e : events) {
            switch (e.state) {
            case steam::kStateConnecting:
                // Host side: an incoming connection. Only one peer, and it must be in our lobby.
                if (role_ == Role::Host && e.conn != conn_ && e.conn != acceptConn_) {
                    if (conn_ == 0 && acceptConn_ == 0) {
                        acceptConn_ = e.conn;
                        acceptRemote_ = e.remoteSteamId;
                        acceptDeadline_ = now + std::chrono::seconds(5);
                    } else {
                        api_.CloseConnection(api_.sockets, e.conn, steam::kEndReasonAppGeneric, "session full", false);
                    }
                }
                break;
            case steam::kStateConnected:
                if (e.conn == conn_ && !connected_) {
                    connected_ = true;
                    sendSeq_ = 0;
                    lastRecvSeq_.fill(0);
                    reliableBacklog_.clear();
                    sendPacket(PacketType::HANDSHAKE_HELLO, nullptr, 0);
                    emit(R"({"event":"peer_connected"})");
                }
                break;
            case steam::kStateClosedByPeer:
            case steam::kStateProblemDetectedLocally:
                api_.CloseConnection(api_.sockets, e.conn, steam::kEndReasonAppGeneric, nullptr, false);
                diagLog("steam: connection closed (" +
                        std::string(e.state == steam::kStateClosedByPeer ? "by peer" : "problem detected locally") +
                        ") reason=" + std::to_string(e.endReason) + " " + e.endDebug);
                if (e.conn == acceptConn_) {
                    acceptConn_ = 0;
                }
                if (e.conn == conn_) {
                    const bool wasConnected = connected_;
                    conn_ = 0;
                    connected_ = false;
                    if (role_ == Role::Host) {
                        peer_ = 0; // the room stays open for someone else
                    }
                    reliableBacklog_.clear();
                    emit(R"({"event":"peer_disconnected"})");
                    // A guest has no reconnect: without leaving, its UI would show "Joining..." forever.
                    if (role_ == Role::Client) {
                        leave();
                        emit(R"({"event":"left"})");
                        emitError(wasConnected ? "connection_lost" : "connect_failed");
                    }
                }
                break;
            default:
                break;
            }
        }

        // The joiner's lobby membership can reach us slightly after its connect request,
        // so membership is re-checked for a few seconds before rejecting.
        if (acceptConn_ != 0) {
            if (isLobbyMember(acceptRemote_)) {
                if (api_.AcceptConnection(api_.sockets, acceptConn_) == steam::kResultOK) {
                    conn_ = acceptConn_;
                    peer_ = acceptRemote_;
                } else {
                    api_.CloseConnection(api_.sockets, acceptConn_, steam::kEndReasonAppGeneric, "accept failed", false);
                }
                acceptConn_ = 0;
            } else if (now >= acceptDeadline_) {
                api_.CloseConnection(api_.sockets, acceptConn_, steam::kEndReasonAppGeneric, "not a lobby member", false);
                acceptConn_ = 0;
            }
        }
    }

    // ---- packets ----------------------------------------------------------------------------
    void receive() {
        if (!connected_) {
            return;
        }
        std::array<steam::SteamNetworkingMessage*, 64> msgs{};
        const int count = api_.ReceiveMessagesOnConnection(api_.sockets, conn_, msgs.data(), static_cast<int>(msgs.size()));
        for (int i = 0; i < count; ++i) {
            handleIncoming(static_cast<const std::uint8_t*>(msgs[static_cast<std::size_t>(i)]->data),
                           msgs[static_cast<std::size_t>(i)]->size);
            api_.ReleaseMessage(msgs[static_cast<std::size_t>(i)]);
        }
    }

    // Everything from the wire is untrusted: validate before it reaches the game.
    void handleIncoming(const std::uint8_t* data, std::int32_t size) {
        if (data == nullptr || size < static_cast<std::int32_t>(sizeof(PacketHeader))) {
            return;
        }
        PacketHeader header{};
        std::memcpy(&header, data, sizeof(header));
        const auto payloadSize = static_cast<std::uint32_t>(size) - static_cast<std::uint32_t>(sizeof(PacketHeader));
        const auto typeByte = static_cast<std::uint8_t>(header.type);
        if (header.magic != kPacketMagic || header.version != kProtocolVersion || (header.flags & ~kFlagLz4) != 0 ||
            header.payload_size != payloadSize || !isKnownPacketType(typeByte)) {
            return;
        }
        const PacketType type = header.type;
        if (isHostOnly(type) && role_ != Role::Client) {
            return; // only the host sends these, so only a client accepts them
        }
        if (isUnreliable(type)) {
            if (header.sequence <= lastRecvSeq_[typeByte]) {
                return; // stale/out-of-order unreliable update
            }
            lastRecvSeq_[typeByte] = header.sequence;
        }
        const std::uint8_t* bodyPtr = data + sizeof(PacketHeader);
        std::uint32_t bodySize = payloadSize;
        std::vector<std::uint8_t> decompressed;
        if ((header.flags & kFlagLz4) != 0) {
            auto plain = lz4DecompressPayload(bodyPtr, bodySize, kMaxPayloadSize);
            if (!plain) {
                diagLog("steam: dropped malformed LZ4 packet type " + std::to_string(typeByte));
                return;
            }
            decompressed = std::move(*plain);
            bodyPtr = decompressed.data();
            bodySize = static_cast<std::uint32_t>(decompressed.size());
        }
        const std::uint32_t fixed = fixedPayloadSize(type);
        if (fixed != 0 && fixed != bodySize) {
            return;
        }
        NetMessage msg{MsgKind::Packet, std::vector<std::uint8_t>(1 + bodySize)};
        msg.data[0] = typeByte;
        if (bodySize != 0) {
            std::memcpy(msg.data.data() + 1, bodyPtr, bodySize);
        }
        if (!g_IncomingQueue.push(std::move(msg))) {
            debugLog("incoming queue full, packet dropped");
        }
    }

    void drainOutgoing() {
        while (auto msg = g_OutgoingQueue.pop()) {
            if (msg->kind == MsgKind::Json) {
                handleCommand(std::string_view(reinterpret_cast<const char*>(msg->data.data()), msg->data.size()));
            } else if (ready_ && connected_) {
                queuePacket(std::move(msg->data));
            }
            // No peer yet: local actions are simply dropped.
        }
    }

    void queuePacket(std::vector<std::uint8_t>&& data) {
        if (data.empty() || !isKnownPacketType(data[0]) || data.size() - 1 > kMaxPayloadSize) {
            return;
        }
        const auto type = static_cast<PacketType>(data[0]);
        const auto payloadSize = static_cast<std::uint32_t>(data.size() - 1);
        const std::uint32_t fixed = fixedPayloadSize(type);
        if ((fixed != 0 && fixed != payloadSize) || (isHostOnly(type) && role_ != Role::Host)) {
            return;
        }
        if (isUnreliable(type)) {
            pendingUnreliable_[data[0]] = std::move(data);
        } else {
            reliableBacklog_.push_back(frame(type, data.data() + 1, payloadSize));
            flushReliable();
        }
    }

    // Steam rejects reliable sends with LimitExceeded once its send buffer is full (e.g. while a
    // park save streams); those packets wait here, in order, instead of being lost.
    void flushReliable() {
        while (connected_ && !reliableBacklog_.empty()) {
            const auto& buffer = reliableBacklog_.front();
            const std::int32_t result = api_.SendMessageToConnection(
                api_.sockets, conn_, buffer.data(), static_cast<std::uint32_t>(buffer.size()), steam::kSendReliable, nullptr);
            if (result == steam::kResultLimitExceeded) {
                return;
            }
            if (result != steam::kResultOK) {
                debugLog("SendMessageToConnection failed (reliable)");
            }
            reliableBacklog_.pop_front();
        }
    }

    void flushUnreliable() {
        for (auto& data : pendingUnreliable_) {
            if (!data.empty()) {
                if (connected_) {
                    sendPacket(static_cast<PacketType>(data[0]), data.data() + 1, static_cast<std::uint32_t>(data.size() - 1));
                }
                data.clear();
            }
        }
    }

    std::vector<std::uint8_t> frame(PacketType type, const std::uint8_t* payload, std::uint32_t payloadSize) {
        std::uint16_t flags = 0;
        const std::uint8_t* wirePtr = payload;
        std::uint32_t wireSize = payloadSize;
        std::vector<std::uint8_t> compressed;
        // LZ4-compress larger reliable payloads (save chunks, blueprints, area regions) when smaller on the wire.
        if (!isUnreliable(type) && payload != nullptr && payloadSize >= 256) {
            if (auto lz4 = lz4CompressPayload(payload, payloadSize)) {
                if (lz4->size() <= kMaxPayloadSize) {
                    compressed = std::move(*lz4);
                    wirePtr = compressed.data();
                    wireSize = static_cast<std::uint32_t>(compressed.size());
                    flags = kFlagLz4;
                }
            }
        }
        const PacketHeader header{kPacketMagic, kProtocolVersion, type, flags, ++sendSeq_, wireSize};
        std::vector<std::uint8_t> buffer(sizeof(header) + wireSize);
        std::memcpy(buffer.data(), &header, sizeof(header));
        if (wireSize != 0) {
            std::memcpy(buffer.data() + sizeof(header), wirePtr, wireSize);
        }
        return buffer;
    }

    void sendPacket(PacketType type, const std::uint8_t* payload, std::uint32_t payloadSize) {
        const std::vector<std::uint8_t> buffer = frame(type, payload, payloadSize);
        const int flags = isUnreliable(type) ? steam::kSendUnreliableNoNagle : steam::kSendReliable;
        const std::int32_t result = api_.SendMessageToConnection(api_.sockets, conn_, buffer.data(),
                                                                 static_cast<std::uint32_t>(buffer.size()), flags, nullptr);
        if (result != steam::kResultOK) {
            debugLog("SendMessageToConnection failed");
        }
    }

    steam::Api api_;
    bool ready_ = false;
    Role role_ = Role::None;
    Pending pending_ = Pending::None;
    steam::SteamAPICall_t call_ = 0;
    std::uint64_t lobby_ = 0;
    std::uint64_t peer_ = 0; // the other player's SteamID (host: accepted joiner, client: lobby owner)
    std::int32_t lobbyType_ = steam::kLobbyTypeFriendsOnly;
    std::unordered_set<std::uint64_t> avatarsSent_;
    steam::HSteamListenSocket listen_ = 0;
    steam::HSteamNetConnection conn_ = 0;
    bool connected_ = false;

    steam::HSteamNetConnection acceptConn_ = 0;
    std::uint64_t acceptRemote_ = 0;
    Clock::time_point acceptDeadline_{};

    std::uint32_t sendSeq_ = 0;
    std::array<std::uint32_t, 256> lastRecvSeq_{};
    std::array<std::vector<std::uint8_t>, 256> pendingUnreliable_{};
    std::deque<std::vector<std::uint8_t>> reliableBacklog_;
};

} // namespace

void startSteamP2P() {
    // Intentionally leaked: the thread lives for the whole process and must never be joined
    // from DllMain (loader lock), nor destroyed while joinable at exit.
    auto* session = new Session();
    std::thread([session] { session->run(); }).detach();
}

} // namespace pz2
