# Wire Protocol & Steamworks P2P Specification (`docs/NETWORK_PROTOCOL.md`)

## 0. Status
Protocol `kProtocolVersion = 0x02`. No packet has crossed two real PCs yet (loopback only). Feature claims: `docs/HANDOFF.md`.

| Tag | Packets |
|---|---|
| `[IMPLEMENTED]` | `0x01` hello (mod version + host game mode `Sandbox`/`Challenge`), `0x02`/`0x03` save transfer (**with LZ4 `kFlagLz4` block compression**), `0x11` ledger (cash + game speed + time of day), `0x20` place (groups, loose parts), `0x21` delete, `0x22` area sync (paths + water add/remove), **`0x23` terrain strokes** (batched brush dabs: push/pull, flatten, chisel, smooth, roughen, terrace, gradient, attract, curl, sharpen, paint, autopaint), **`0x30` staff hire/fire, exhibit add/remove, habitat animal contraceptive/remove, & research tier unlocks**, **`0x31` habitat animal waypoints/SyncUUID sync**, `0x10` presence (camera pose + walk mode), `0x12` presence avatar + **whitelisted player actions (`k = "action"`: emotes, props, sitting, world interactions, hold hands)** |
| `[OFF]` | `0x22` fence payloads: sent, but receiver ignores them (`c_bApplyFences`) |
| `[PLANNED]` | Conservation credits setter (no engine API found) |

Security rule: no incoming field (`0x02`, `0x20`, `0x22` or any other) may name a local path. Attachments and saves are
written only to fixed names (`rx_<n>.bin`, `rx_save.bin`) in `<game>\PZ2Coop\`.

## 1. Transport Layer (`ISteamNetworkingSockets`)
`version.dll` resolves `SteamInternal_FindOrCreateUserInterface` from the in-process `steam_api64.dll` (AppID `3219030` from the running game; never Spacewar `480`) and establishes two virtual channels over Valve's Steam Datagram Relay (SDR):

| Virtual Channel | Send Flags | Purpose | Max Frequency |
| :--- | :--- | :--- | :--- |
| **Channel 0 (Reliable)** | `k_nSteamNetworkingSend_Reliable` | Save handshake, group/scenery place+delete, path area sync. `[PLANNED]` terrain, animal/staff actions. | Event-driven |
| **Channel 1 (Unreliable)** | `k_nSteamNetworkingSend_UnreliableNoNagle` | 1Hz host ledger, 10Hz presence (`0x10`). `[PLANNED]` 10Hz animal waypoints. | 20 Hz |

## 2. Room Code Encoding (Base62 `CSteamID`)
To allow effortless joining without manual IP configuration:
- A 64-bit Steam Lobby ID (`0x01860000...`) has a fixed upper bits prefix (`AccountType = Chat`, `Universe = Public`).
- Strip the constant upper 32 bits and Base62-encode the lower 32-bit Lobby Instance ID into a 6-character alphanumeric Room Code (e.g., `PZ-8K4M`).
- Decoding reconstructs the full 64-bit `CSteamID` and calls `SteamMatchmaking()->JoinLobby(lobbySteamID)`.

## 3. Packet Header Structure (C++20 `pragma pack(1)`)
All packets transmitted across `ISteamNetworkingSockets` begin with a fixed 16-byte binary header:

```cpp
#pragma pack(push, 1)
enum class PacketType : uint8_t {
    HANDSHAKE_HELLO       = 0x01,
    SAVE_CHUNK_DATA       = 0x02,
    SAVE_LOAD_COMMIT      = 0x03,
    CURSOR_TRANSFORM_20HZ = 0x10,
    LEDGER_SYNC_1HZ       = 0x11,
    ACTION_PLACE_OBJECT   = 0x20,
    ACTION_DELETE_SPATIAL = 0x21,
    ACTION_PATH_STAMP     = 0x22,
    ACTION_TERRAIN_STROKE = 0x23,
    ACTION_ANIMAL_EVENT   = 0x30,
    ANIMAL_WAYPOINT_10HZ  = 0x31
};

struct PacketHeader {
    uint32_t   magic;          // Always 0x505A3243 ('PZ2C')
    uint8_t    version;        // Protocol version (0x01)
    PacketType type;           // PacketType enum
    uint16_t   flags;          // Bit 0: LZ4 Compressed
    uint32_t   sequence;       // Monotonic packet sequence number
    uint32_t   payload_size;   // Uncompressed/compressed byte count following header
};
#pragma pack(pop)

```

## 4. Core Payload Schemas

### `CURSOR_TRANSFORM_20HZ` (Channel 1 — 32 Bytes) `[IMPLEMENTED]` presence
Sent by `src/ovl_mod/pz2coop.presence.lua` every 0.1 s while a role is set and a peer (or solo mirror) exists.
Lua JSON keys `cx,cy,cz,px,py,pz,yaw,m` (metres / radians). The DLL keeps only the newest per 50 ms tick.
A 28-byte payload from an older DLL fails the size check and is dropped (no other packet is affected).

```cpp
struct CursorTransformPayload {
    float cam_pos[3];      // X, Y, Z camera (eye) world position
    float cursor_pos[3];   // ground point: feet while walking, orbit centre while flying
    float cursor_yaw;      // camera yaw in radians (vCameraYPR:X())
    float mode;            // 0 = flying build camera, 1 = walking first person, 2 = walking third person
};

```

### `PRESENCE_AVATAR` `0x12` (Channel 0 — JSON) `[IMPLEMENTED]` (verified in retail game)
Sent once per connection (and in loopback mirror mode) by `src/ovl_mod/pz2coop.presence.lua`. Carries the player's
sanitized `tAvatar` (`version`, `group`, `actor`, `voice`, `variant`, `skin`, `parts`, `items.Hats`). The receiver
validates every field as a trust boundary (no paths or dots, bounded sizes, JSON `"1".."4"` colour keys normalized
to integer keys) and renders the friend with the vehicle-driver recipe (`StartScreenAvatar:Create(..., "friend", "Static")`)
while walking.

### `ACTION_DELETE_SPATIAL` (Channel 0 — JSON, protocol v2)
Protocol v1 packed this as a fixed 24-byte struct (asset hash, x/y/z cm, radius mm), which silently dropped
every other field. Since v2 (`kProtocolVersion = 0x02`, 2026-11-12) it is a JSON packet like
`ACTION_PLACE_OBJECT`, so all fields survive the wire:
`{h, x, y, z (cm), r (mm), k = "p" for a loose part, n = part resource name, p = 1 if the object belongs to the
receiver (it was the sender's copy of the receiver's build)}`.
Building-group deletes put the sender's **group part ID** in `h` as a lookup hint: both peers loaded the same
save, so loaded IDs usually match. The receiver only deletes that group if its position lies within `r` of the
sent position (or of the shared position it recorded when it placed the copy); position stays authoritative
(CLAUDE.md rule 3).

### `ACTION_PATH_STAMP` 0x22 — area replace for paths `[IMPLEMENTED]` and fences `[OFF]` (Channel 0 — JSON + optional blueprint)
`{k = "path" | "fence", x0,y0,z0,x1,y1,z1 = changed area (cm)}` plus
- path: `n` = path volume chunks now in the area (0 = area emptied), `cx,cy,cz` = centre of their AABB (cm),
  attachment = blueprint holding those chunks;
- fence: `posts`, `panels` = every connected fence touching the area as `GetAllData()` tables
  `{f = plain fields, v = {name = [x,y,z] metres}, r = {name = post index}}`, local IDs stripped.
The receiver removes its own paths / fences in the area and places / rebuilds the sent content
(`src/ovl_mod/pz2coop.regionsync.lua`). `ox` (cm) appears only on solo-test loopback copies.

### `SAVE_CHUNK_DATA` / `SAVE_LOAD_COMMIT` (Channel 0, host only)
`SAVE_CHUNK_DATA` payload: `uint32 chunk_index, uint32 chunk_count, bytes[≤256 KiB]`, sent in order.
`SAVE_LOAD_COMMIT` payload: `{}` (JSON). The client writes the reassembled file as `PZ2Coop/rx_save.bin`
and only accepts it if every chunk arrived in sequence. Reliable sends that hit Steam's send-buffer
limit (`k_EResultLimitExceeded`) wait in an ordered backlog instead of being dropped.

### Variable-size action packets (`0x20`, `0x22`, `0x23`, `0x30`, `0x31`)
Payload: UTF-8 JSON object, optionally followed by `0x00` and a binary attachment (e.g. a blueprint
file for `ACTION_PLACE_OBJECT`, whose JSON is `{"x":cm,"y":cm,"z":cm}` = AABB centre of the group).

### `LEDGER_SYNC_1HZ` (Channel 1 — 20 Bytes) `[IMPLEMENTED]` cash + game speed + time of day; CC `[PLANNED]`

```cpp
struct LedgerSyncPayload {
    int64_t  cash_cents;           // Authoritative Host cash
    int32_t  conservation_credits; // Authoritative Host CC
    uint32_t game_speed_state;     // 0 = Paused, 1 = 1x, 2 = 2x, 3 = 5x
    float    time_of_day;          // Normalized [0.0, 24.0]
};

```

## 5. Session control (Lua ⇄ version.dll, local only — never sent over the network)
JSON lines on the memory bridge (`src/proxy_dll/file_bridge.hpp`). Sent by `src/ovl_mod/pz2coop.ui.lua`
for the Esc-menu Co-op screen. There are no hotkeys any more.

| Command `{"cmd":...}` | Fields | Result |
| :--- | :--- | :--- |
| `host` | – | Creates a 2-player lobby (type from `privacy`, default Friends only) → `room_code` event |
| `join` | `code` (`PZ-xxxxxx`) **or** `lobby` (decimal lobby SteamID from the friends list) | → `lobby_joined`, later `peer_connected` |
| `leave` | – | → `left` |
| `privacy` | `type`: `friends` \| `public` | Sets the type for the next lobby, and live via `SetLobbyType` while hosting → `status` |
| `invite` | `id` (decimal friend SteamID) | `InviteUserToLobby` → `invited` or `error invite_failed` |
| `status` | – | → `status` |
| `friends` | `reset?` (`"1"`: resend all pictures, used once per Lua state) | → `friends`, then up to 8 `avatar` events for ids not sent yet |
| `clipboard` | `text` (room-code characters only, ≤16) | Copies to the Windows clipboard (handled in `ipc_bridge.cpp`) |

| Event `{"event":...}` | Fields |
| :--- | :--- |
| `status` | `steam_ready`, `role` (`none`/`host`/`client`), `connected`, `pending`, `privacy`, `room_code?`, `self_name?`, `self_id?`, `partner_name?`, `partner_id?`, `ping?` (ms) |
| `friends` | `available` (ISteamFriends resolved), `list`: up to 40 online friends, each `{id, name, playing, lobby}`. `lobby` is non-empty when the friend is in a lobby of this game (= hosting/in a co-op room); those come first, then PZ2 players |
| `room_code`, `lobby_joined`, `peer_connected`, `peer_disconnected`, `left` | as before. A guest whose connection closes also gets `left` + `error` (`connect_failed` before it was connected, `connection_lost` after): it has no reconnect |
| `save_progress` | Guest only, one per received park-save chunk: `got`, `total` (chunks), `bytes` so far. Written by `file_bridge.cpp`; shown as "Step 3 of 3" on the Co-op screen |
| `avatar` | `id`, `size` (32), `rgb`: base64 of size×size×3 bytes (Steam small avatar, alpha dropped). Lua stores it in data-store key `ui.pz2coopAv_<id>` as `"<size>:<rgb>"`; JS paints it on a canvas |
| `invited` | `id` |
| `error` | `code`: `steam_not_ready`, `already_in_session`, `invalid_room_code`, `create_lobby_failed`, `join_lobby_failed`, `listen_socket_failed`, `connect_failed`, `connection_lost`, `zoo_transfer_failed` (load commit without all chunks), `invite_failed`, `invalid_privacy`, `unknown_cmd` |

Persona names are user-controlled and pass through `jsonQuote` (escaped, ~64-byte cap); the UI shows them
as plain text, never inside a localisation tag.
