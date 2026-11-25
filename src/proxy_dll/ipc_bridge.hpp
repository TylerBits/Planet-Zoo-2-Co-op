#pragma once

#include <cstdint>
#include <string>
#include <string_view>

namespace pz2 {

// Game UI (Coherent Gameface JS) connects to ws://127.0.0.1:27099.
// Tools/tests can use the message-mode pipe \\.\pipe\PZ2CoopPipe instead.
//
// Message format (both transports):
//   UI -> DLL  text   {"cmd":"host"} | {"cmd":"join","code":"PZ-abc123"} | {"cmd":"leave"} | {"cmd":"status"}
//                     {"cmd":"apply_begin"} | {"cmd":"apply_end"}   (echo-suppression guard)
//   UI -> DLL  binary [PacketType byte][payload]  -> sent to the peer
//   DLL -> UI  text   {"event":"steam_ready"|"room_code"|"lobby_joined"|"peer_connected"|"peer_disconnected"|"left"|"status"|"error",...}
//   DLL -> UI  binary [PacketType byte][payload]  <- received from the peer
// On the pipe, a message starting with '{' is text; anything else is binary.
inline constexpr std::uint16_t kIpcPort = 27099;
inline constexpr wchar_t kPipeName[] = L"\\\\.\\pipe\\PZ2CoopPipe";

// RFC 6455 Sec-WebSocket-Accept value for a client's Sec-WebSocket-Key.
std::string websocketAcceptKey(std::string_view clientKey);

// Starts the IPC thread (sole producer of g_OutgoingQueue, sole consumer of g_IncomingQueue).
void startIpcBridge();

} // namespace pz2
