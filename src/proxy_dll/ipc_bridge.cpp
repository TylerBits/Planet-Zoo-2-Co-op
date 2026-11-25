#include "ipc_bridge.hpp"

#include "diag.hpp"
#include "file_bridge.hpp"
#include "mem_bridge.hpp"
#include "spsc_queue.hpp"
#include "steam_p2p.hpp"

#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <bcrypt.h>
#include <wincrypt.h>

#include <algorithm>
#include <cctype>
#include <chrono>
#include <cstring>
#include <fstream>
#include <thread>
#include <vector>

namespace pz2 {

std::string websocketAcceptKey(std::string_view clientKey) {
    std::string input(clientKey);
    input += "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
    UCHAR digest[20] = {};
    if (!BCRYPT_SUCCESS(BCryptHash(BCRYPT_SHA1_ALG_HANDLE, nullptr, 0, reinterpret_cast<PUCHAR>(input.data()),
                                   static_cast<ULONG>(input.size()), digest, sizeof(digest)))) {
        return {};
    }
    char out[64] = {};
    DWORD outLen = sizeof(out);
    if (!CryptBinaryToStringA(digest, sizeof(digest), CRYPT_STRING_BASE64 | CRYPT_STRING_NOCRLF, out, &outLen)) {
        return {};
    }
    return std::string(out, outLen);
}

namespace {

using Clock = std::chrono::steady_clock;

constexpr std::size_t kMaxIpcMessage = 1 + kMaxPayloadSize; // [type][payload]
#ifdef PZ2COOP_ENABLE_LEGACY_IPC
constexpr std::size_t kMaxHandshake = 8192;
constexpr DWORD kPipeBuffer = 1 << 20;

std::string toLower(std::string_view s) {
    std::string out(s);
    std::transform(out.begin(), out.end(), out.begin(),
                   [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
    return out;
}

bool sendAll(SOCKET s, const char* data, std::size_t size) {
    int stalls = 0;
    while (size > 0) {
        const int chunk = static_cast<int>(std::min<std::size_t>(size, 1 << 20));
        const int sent = send(s, data, chunk, 0);
        if (sent > 0) {
            data += sent;
            size -= static_cast<std::size_t>(sent);
            stalls = 0;
            continue;
        }
        if (WSAGetLastError() != WSAEWOULDBLOCK || ++stalls > 20) {
            return false; // UI stopped reading for ~2 s: treat as dead
        }
        fd_set writable;
        FD_ZERO(&writable);
        FD_SET(s, &writable);
        timeval timeout{0, 100000};
        select(0, nullptr, &writable, nullptr, &timeout);
    }
    return true;
}
#endif

std::filesystem::path gameDir() {
    wchar_t path[MAX_PATH] = {};
    const DWORD len = GetModuleFileNameW(nullptr, path, MAX_PATH);
    return std::filesystem::path(std::wstring(path, len)).parent_path();
}

class IpcServer {
public:
    [[noreturn]] void run() {
        using namespace std::chrono_literals;
#ifdef PZ2COOP_ENABLE_LEGACY_IPC
        WSADATA wsa{};
        const bool winsock = WSAStartup(MAKEWORD(2, 2), &wsa) == 0;
        if (!winsock) {
            debugLog("WSAStartup failed; WebSocket bridge disabled");
        }
        auto nextListen = Clock::now();
        auto nextPipe = Clock::now();
#endif
        auto nextFiles = Clock::now();
        const auto deliverFn = [this](bool isText, std::string_view data) { deliver(isText, data); };
        for (;;) {
            const auto now = Clock::now();
#ifdef PZ2COOP_ENABLE_LEGACY_IPC
            if (winsock && listen_ == INVALID_SOCKET && now >= nextListen) {
                openListener();
                nextListen = now + 2s;
            }
            if (pipe_ == INVALID_HANDLE_VALUE && now >= nextPipe) {
                openPipe();
                nextPipe = now + 2s;
            }
#endif
            if (!files_.isOpen() && now >= nextFiles) {
                if (!files_.open(gameDir() / kFileBridgeDirName)) {
                    debugLog("cannot open the PZ2Coop file bridge folder, retrying");
                }
                nextFiles = now + 2s;
            }
#ifdef PZ2COOP_ENABLE_LEGACY_IPC
            pollSockets(); // blocks up to 2 ms
            pollPipe();
#else
            std::this_thread::sleep_for(2ms);
#endif
            mem_.poll(files_, deliverFn, now);
            files_.poll(deliverFn, now);
            pollAutotest(now);
            pumpMessages();
            forwardIncoming();
        }
    }

private:
    // ---- shared ---------------------------------------------------------------------------
    void deliver(bool isText, std::string_view data) {
        if (data.empty() || data.size() > kMaxIpcMessage) {
            return;
        }
        NetMessage msg;
        if (isText) {
            const std::string cmd = jsonGetString(data, "cmd");
            if (cmd == "apply_begin") {
                g_IsApplyingRemoteAction.store(true, std::memory_order_release);
                return;
            }
            if (cmd == "apply_end") {
                g_RemoteApplyEndTick.store(GetTickCount64(), std::memory_order_release);
                g_IsApplyingRemoteAction.store(false, std::memory_order_release);
                return;
            }
            if (cmd == "clipboard") {
                copyToClipboard(data);
                return;
            }
            if (cmd.empty()) {
                return;
            }
            msg.kind = MsgKind::Json;
        } else {
            const auto type = static_cast<PacketType>(static_cast<std::uint8_t>(data[0]));
            // Echo suppression: actions emitted while Lua replays a remote action are not re-sent.
            if (isEchoGuarded(type) && g_IsApplyingRemoteAction.load(std::memory_order_acquire)) {
                return;
            }
            msg.kind = MsgKind::Packet;
        }
        msg.data.assign(data.begin(), data.end());
        if (!g_OutgoingQueue.push(std::move(msg))) {
            debugLog("outgoing queue full, message dropped");
        }
    }

    void forwardIncoming() {
        while (auto msg = g_IncomingQueue.pop()) {
            const bool isText = msg->kind == MsgKind::Json;
            const std::string_view data(reinterpret_cast<const char*>(msg->data.data()), msg->data.size());
            if (isText) {
                noteEvent(data);
            }
#ifdef PZ2COOP_ENABLE_LEGACY_IPC
            if (wsOpen_) {
                sendWsFrame(isText ? 0x1 : 0x2, data);
            }
            if (pipeConnected_) {
                writePipe(data);
            }
#endif
            files_.forward(*msg);
        }
    }

    // Copy button of the co-op screen: Lua sends {"cmd":"clipboard","text":"PZ-xxxxxx"}.
    // Only room-code characters are accepted.
    void copyToClipboard(std::string_view json) {
        std::string text;
        for (const char c : jsonGetString(json, "text")) {
            if ((c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '-') {
                text.push_back(c);
            }
        }
        if (!text.empty() && text.size() <= 16) {
            setClipboardText(text);
        }
    }

    // Shows session state outside the game: room code on the clipboard, status.txt.
    void noteEvent(std::string_view json) {
        const std::string event = jsonGetString(json, "event");
        if (event == "room_code") {
            roomCode_ = "PZ-" + jsonGetString(json, "code");
            setClipboardText(roomCode_);
        } else if (event == "left") {
            roomCode_.clear();
        }
        files_.writeStatus("room_code: " + roomCode_ + "\nlast_event: " + std::string(json) + "\n");
    }

    // SetClipboardData needs an owner window, and the owner must answer clipboard messages,
    // hence a message-only window pumped from this loop.
    void setClipboardText(std::string_view text) {
        if (clipWindow_ == nullptr) {
            clipWindow_ = CreateWindowExW(0, L"STATIC", nullptr, 0, 0, 0, 0, 0, HWND_MESSAGE, nullptr, nullptr, nullptr);
        }
        if (clipWindow_ == nullptr || !OpenClipboard(clipWindow_)) {
            return;
        }
        EmptyClipboard();
        if (const HGLOBAL mem = GlobalAlloc(GMEM_MOVEABLE, (text.size() + 1) * sizeof(wchar_t))) {
            if (auto* w = static_cast<wchar_t*>(GlobalLock(mem))) {
                for (std::size_t i = 0; i < text.size(); ++i) {
                    w[i] = static_cast<wchar_t>(static_cast<unsigned char>(text[i]));
                }
                w[text.size()] = 0;
                GlobalUnlock(mem);
                if (SetClipboardData(CF_UNICODETEXT, mem) == nullptr) {
                    GlobalFree(mem);
                }
            } else {
                GlobalFree(mem);
            }
        }
        CloseClipboard();
    }

    void pumpMessages() {
        if (clipWindow_ == nullptr) {
            return;
        }
        MSG m{};
        while (PeekMessageW(&m, nullptr, 0, 0, PM_REMOVE)) {
            DispatchMessageW(&m);
        }
    }

    // Dev-only autonomous live-game test trigger (tools/test_live_game.py): if <game>\PZ2Coop\autotest.txt
    // exists once Lua is alive, read its plan name, delete the file immediately, and deliver an autotest event.
    void pollAutotest(Clock::time_point now) {
        if (!files_.alive() || now < nextAutotest_) {
            return;
        }
        nextAutotest_ = now + std::chrono::seconds(1);
        const auto trigger = gameDir() / kFileBridgeDirName / L"autotest.txt";
        std::error_code ec;
        if (!std::filesystem::is_regular_file(trigger, ec)) {
            return;
        }
        std::string raw;
        {
            std::ifstream in(trigger, std::ios::binary);
            if (in) {
                raw.resize(256);
                in.read(raw.data(), static_cast<std::streamsize>(raw.size()));
                raw.resize(static_cast<std::size_t>(in.gcount()));
            }
        }
        std::filesystem::remove(trigger, ec);
        std::string plan;
        for (const char c : raw) {
            if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || c == '-' ||
                c == ',' || c == '.') {
                plan.push_back(c);
                if (plan.size() >= 128) {
                    break;
                }
            }
        }
        if (plan.empty()) {
            plan = "full";
        }
        diagLog("autotest: triggering plan '" + plan + "'");
        NetMessage msg;
        msg.kind = MsgKind::Json;
        const std::string line = std::string(R"({"event":"autotest","plan":")") + plan + "\"}";
        msg.data.assign(line.begin(), line.end());
        files_.forward(msg);
    }

#ifdef PZ2COOP_ENABLE_LEGACY_IPC
    // A UI that disconnects mid-replay must not leave the echo guard stuck on.
    static void resetGuard() { g_IsApplyingRemoteAction.store(false, std::memory_order_release); }

    // ---- WebSocket server ---------------------------------------------------------------
    void openListener() {
        const SOCKET s = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
        if (s == INVALID_SOCKET) {
            return;
        }
        const BOOL exclusive = TRUE;
        setsockopt(s, SOL_SOCKET, SO_EXCLUSIVEADDRUSE, reinterpret_cast<const char*>(&exclusive), sizeof(exclusive));
        sockaddr_in addr{};
        addr.sin_family = AF_INET;
        addr.sin_port = htons(kIpcPort);
        addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        u_long nonBlocking = 1;
        if (bind(s, reinterpret_cast<const sockaddr*>(&addr), sizeof(addr)) != 0 || listen(s, 4) != 0 ||
            ioctlsocket(s, FIONBIO, &nonBlocking) != 0) {
            debugLog("cannot listen on 127.0.0.1:27099 (port in use?), retrying");
            closesocket(s);
            return;
        }
        listen_ = s;
        debugLog("WebSocket bridge listening on ws://127.0.0.1:27099");
    }

    void pollSockets() {
        if (listen_ == INVALID_SOCKET && ws_ == INVALID_SOCKET) {
            std::this_thread::sleep_for(std::chrono::milliseconds(2));
            return;
        }
        fd_set readable;
        FD_ZERO(&readable);
        if (listen_ != INVALID_SOCKET) {
            FD_SET(listen_, &readable);
        }
        if (ws_ != INVALID_SOCKET) {
            FD_SET(ws_, &readable);
        }
        timeval timeout{0, 2000};
        if (select(0, &readable, nullptr, nullptr, &timeout) <= 0) {
            return;
        }
        if (listen_ != INVALID_SOCKET && FD_ISSET(listen_, &readable)) {
            acceptClient();
        }
        if (ws_ != INVALID_SOCKET && FD_ISSET(ws_, &readable)) {
            readClient();
        }
    }

    void acceptClient() {
        const SOCKET c = accept(listen_, nullptr, nullptr);
        if (c == INVALID_SOCKET) {
            return;
        }
        closeWs(); // one UI at a time; a reconnecting HUD replaces the old socket
        u_long nonBlocking = 1;
        ioctlsocket(c, FIONBIO, &nonBlocking);
        const BOOL noDelay = TRUE;
        setsockopt(c, IPPROTO_TCP, TCP_NODELAY, reinterpret_cast<const char*>(&noDelay), sizeof(noDelay));
        ws_ = c;
    }

    void closeWs() {
        if (ws_ != INVALID_SOCKET) {
            closesocket(ws_);
            resetGuard();
        }
        ws_ = INVALID_SOCKET;
        wsOpen_ = false;
        rx_.clear();
        fragment_.clear();
    }

    void readClient() {
        char buf[65536];
        const int got = recv(ws_, buf, sizeof(buf), 0);
        if (got == 0 || (got < 0 && WSAGetLastError() != WSAEWOULDBLOCK)) {
            closeWs();
            return;
        }
        if (got < 0) {
            return;
        }
        rx_.append(buf, static_cast<std::size_t>(got));
        if (!wsOpen_ && !handshake()) {
            return;
        }
        parseFrames();
    }

    void rejectHandshake(const char* status) {
        const std::string response = std::string("HTTP/1.1 ") + status + "\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
        sendAll(ws_, response.data(), response.size());
        closeWs();
    }

    bool handshake() {
        const std::size_t end = rx_.find("\r\n\r\n");
        if (end == std::string::npos) {
            if (rx_.size() > kMaxHandshake) {
                closeWs();
            }
            return false;
        }
        const std::string head = rx_.substr(0, end + 2);
        rx_.erase(0, end + 4);
        const std::string lower = toLower(head);
        const auto header = [&](std::string_view name) -> std::string {
            const std::string needle = "\r\n" + std::string(name) + ":";
            const std::size_t at = lower.find(needle);
            if (at == std::string::npos) {
                return {};
            }
            std::size_t begin = at + needle.size();
            const std::size_t stop = head.find("\r\n", begin);
            while (begin < stop && (head[begin] == ' ' || head[begin] == '\t')) {
                ++begin;
            }
            std::size_t last = stop;
            while (last > begin && (head[last - 1] == ' ' || head[last - 1] == '\t')) {
                --last;
            }
            return head.substr(begin, last - begin);
        };

        if (!lower.starts_with("get ") || toLower(header("upgrade")) != "websocket") {
            rejectHandshake("400 Bad Request");
            return false;
        }
        // Browsers send their page origin; refuse web pages so a random site can't drive the session.
        // ponytail: blocklist http(s) origins only; switch to an allowlist once Gameface's origin is confirmed.
        const std::string origin = toLower(header("origin"));
        if (origin.starts_with("http://") || origin.starts_with("https://")) {
            rejectHandshake("403 Forbidden");
            return false;
        }
        const std::string accept = websocketAcceptKey(header("sec-websocket-key"));
        if (header("sec-websocket-key").empty() || accept.empty()) {
            rejectHandshake("400 Bad Request");
            return false;
        }
        const std::string response = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                                     "Sec-WebSocket-Accept: " + accept + "\r\n\r\n";
        if (!sendAll(ws_, response.data(), response.size())) {
            closeWs();
            return false;
        }
        wsOpen_ = true;
        return true;
    }

    void parseFrames() {
        while (ws_ != INVALID_SOCKET && rx_.size() >= 2) {
            const auto b0 = static_cast<std::uint8_t>(rx_[0]);
            const auto b1 = static_cast<std::uint8_t>(rx_[1]);
            const bool fin = (b0 & 0x80) != 0;
            const std::uint8_t opcode = b0 & 0x0F;
            const bool masked = (b1 & 0x80) != 0;
            std::uint64_t length = b1 & 0x7F;
            std::size_t pos = 2;
            if (length == 126) {
                if (rx_.size() < 4) {
                    return;
                }
                length = (std::uint64_t{static_cast<std::uint8_t>(rx_[2])} << 8) | static_cast<std::uint8_t>(rx_[3]);
                pos = 4;
            } else if (length == 127) {
                if (rx_.size() < 10) {
                    return;
                }
                length = 0;
                for (std::size_t i = 2; i < 10; ++i) {
                    length = (length << 8) | static_cast<std::uint8_t>(rx_[i]);
                }
                pos = 10;
            }
            // Clients must mask; reserved bits must be clear; cap size before allocating.
            if (!masked || (b0 & 0x70) != 0 || length > kMaxIpcMessage) {
                closeWs();
                return;
            }
            const std::size_t payloadLen = static_cast<std::size_t>(length);
            if (rx_.size() < pos + 4 + payloadLen) {
                return;
            }
            const char* mask = rx_.data() + pos;
            std::string payload = rx_.substr(pos + 4, payloadLen);
            for (std::size_t i = 0; i < payload.size(); ++i) {
                payload[i] = static_cast<char>(payload[i] ^ mask[i & 3]);
            }
            rx_.erase(0, pos + 4 + payloadLen);

            switch (opcode) {
            case 0x0: // continuation
                if (fragmentOpcode_ == 0 || fragment_.size() + payload.size() > kMaxIpcMessage) {
                    closeWs();
                    return;
                }
                fragment_ += payload;
                if (fin) {
                    deliver(fragmentOpcode_ == 0x1, fragment_);
                    fragment_.clear();
                    fragmentOpcode_ = 0;
                }
                break;
            case 0x1:
            case 0x2:
                if (fin) {
                    deliver(opcode == 0x1, payload);
                } else {
                    fragment_ = std::move(payload);
                    fragmentOpcode_ = opcode;
                }
                break;
            case 0x8: // close
                sendWsFrame(0x8, {});
                closeWs();
                return;
            case 0x9: // ping
                sendWsFrame(0xA, payload);
                break;
            default: // pong / unknown control frames
                break;
            }
        }
    }

    void sendWsFrame(std::uint8_t opcode, std::string_view payload) {
        std::string frame;
        frame.reserve(payload.size() + 10);
        frame.push_back(static_cast<char>(0x80 | opcode));
        if (payload.size() < 126) {
            frame.push_back(static_cast<char>(payload.size()));
        } else if (payload.size() <= 0xFFFF) {
            frame.push_back(static_cast<char>(126));
            frame.push_back(static_cast<char>((payload.size() >> 8) & 0xFF));
            frame.push_back(static_cast<char>(payload.size() & 0xFF));
        } else {
            frame.push_back(static_cast<char>(127));
            for (int shift = 56; shift >= 0; shift -= 8) {
                frame.push_back(static_cast<char>((static_cast<std::uint64_t>(payload.size()) >> shift) & 0xFF));
            }
        }
        frame.append(payload);
        if (!sendAll(ws_, frame.data(), frame.size())) {
            closeWs();
        }
    }

    // ---- named pipe (non-blocking, polled on the same thread so the SPSC queues keep one producer) ----
    void openPipe() {
        // FIRST_PIPE_INSTANCE: fail rather than share a pipe name another process squatted on.
        const HANDLE h = CreateNamedPipeW(kPipeName, PIPE_ACCESS_DUPLEX | FILE_FLAG_FIRST_PIPE_INSTANCE,
                                          PIPE_TYPE_MESSAGE | PIPE_READMODE_MESSAGE | PIPE_NOWAIT | PIPE_REJECT_REMOTE_CLIENTS,
                                          1, kPipeBuffer, kPipeBuffer, 0, nullptr);
        if (h == INVALID_HANDLE_VALUE) {
            debugLog("cannot create \\\\.\\pipe\\PZ2CoopPipe, retrying");
            return;
        }
        pipe_ = h;
    }

    void disconnectPipe() {
        DisconnectNamedPipe(pipe_);
        pipeConnected_ = false;
        pipeRx_.clear();
        resetGuard();
    }

    void pollPipe() {
        if (pipe_ == INVALID_HANDLE_VALUE) {
            return;
        }
        if (!pipeConnected_) {
            // ponytail: PIPE_NOWAIT polling instead of overlapped I/O; fine for one local client.
            if (ConnectNamedPipe(pipe_, nullptr)) {
                pipeConnected_ = true;
            } else {
                const DWORD err = GetLastError();
                if (err == ERROR_PIPE_CONNECTED) {
                    pipeConnected_ = true;
                } else if (err == ERROR_NO_DATA) {
                    DisconnectNamedPipe(pipe_); // client came and went; listen again
                }
            }
            if (!pipeConnected_) {
                return;
            }
            pipeRx_.clear();
        }
        for (;;) {
            char buf[65536];
            DWORD got = 0;
            if (ReadFile(pipe_, buf, sizeof(buf), &got, nullptr)) {
                pipeRx_.append(buf, got);
                deliver(!pipeRx_.empty() && pipeRx_[0] == '{', pipeRx_);
                pipeRx_.clear();
                continue;
            }
            const DWORD err = GetLastError();
            if (err == ERROR_MORE_DATA) {
                pipeRx_.append(buf, got);
                if (pipeRx_.size() > kMaxIpcMessage) {
                    disconnectPipe();
                    return;
                }
                continue;
            }
            if (err != ERROR_NO_DATA) {
                disconnectPipe(); // broken pipe / client gone
            }
            return;
        }
    }

    void writePipe(std::string_view data) {
        DWORD written = 0;
        if (!WriteFile(pipe_, data.data(), static_cast<DWORD>(data.size()), &written, nullptr)) {
            const DWORD err = GetLastError();
            if (err == ERROR_NO_DATA || err == ERROR_BROKEN_PIPE || err == ERROR_PIPE_NOT_CONNECTED) {
                disconnectPipe();
            }
        }
        // ponytail: a full pipe buffer drops the message; the pipe is a tooling/fallback channel.
    }

    SOCKET listen_ = INVALID_SOCKET;
    SOCKET ws_ = INVALID_SOCKET;
    bool wsOpen_ = false;
    std::string rx_;
    std::string fragment_;
    std::uint8_t fragmentOpcode_ = 0;

    HANDLE pipe_ = INVALID_HANDLE_VALUE;
    bool pipeConnected_ = false;
    std::string pipeRx_;
#endif

    FileBridge files_; // line protocol core (+ file transport, dead in retail)
    MemBridge mem_;    // shared Lua-table transport
    HWND clipWindow_ = nullptr;
    std::string roomCode_;
    Clock::time_point nextAutotest_ = Clock::now();
};

} // namespace

void startIpcBridge() {
    // Intentionally leaked; see startSteamP2P().
    auto* server = new IpcServer();
    std::thread([server] { server->run(); }).detach();
}

} // namespace pz2
