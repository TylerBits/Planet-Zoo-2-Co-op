// Runtime checks for the pure logic in the proxy (run via `ctest` or directly).
#include "file_bridge.hpp"
#include "ipc_bridge.hpp"
#include "lz4_codec.hpp"
#include "mem_bridge.hpp"
#include "spsc_queue.hpp"
#include "steam_p2p.hpp"
#include "ui_overlay.hpp"
#include "vehicle_patch.hpp"

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <limits>
#include <memory>
#include <thread>

namespace {
int g_failures = 0;

void check(bool ok, const char* what) {
    if (!ok) {
        std::printf("FAIL: %s\n", what);
        ++g_failures;
    }
}
} // namespace

int main(int argc, char** argv) {
    // Offline run of the in-game UI overlay build (tools/test_ui_overlay.py compares it with the Python reference):
    //   pz2coop_selftest --ui-overlay <game dir> <pack UI dir>
    if (argc == 4 && std::strcmp(argv[1], "--ui-overlay") == 0) {
        std::string error;
        const bool ok = pz2::buildUiOverlay(argv[2], argv[3], false, error);
        std::printf("ui overlay: %s %s\n", ok ? "ok" : "FAILED", error.c_str());
        return ok ? 0 : 1;
    }
    // Room codes round-trip and reject garbage.
    for (const std::uint64_t id : {0x0186000000000000ULL, 0x0186000012345678ULL, 0x01860000FFFFFFFFULL}) {
        const std::string code = pz2::encodeRoomCode(id);
        check(code.size() == 6, "room code is 6 chars");
        check(pz2::decodeRoomCode(code) == id, "room code round-trips");
        check(pz2::decodeRoomCode("PZ-" + code) == id, "PZ- prefix accepted");
    }
    check(pz2::encodeRoomCode(0x0110000100000001ULL).empty(), "non-lobby SteamID rejected");
    check(!pz2::decodeRoomCode("zzzzzz"), "value above 32 bits rejected");
    check(!pz2::decodeRoomCode("abc"), "short code rejected");
    check(!pz2::decodeRoomCode("ab$def"), "non-Base62 char rejected");

    // RFC 6455 section 1.3 example.
    check(pz2::websocketAcceptKey("dGhlIHNhbXBsZSBub25jZQ==") == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", "websocket accept key");

    check(pz2::jsonGetString(R"({"cmd" : "join", "code":"PZ-abc123"})", "code") == "PZ-abc123", "json string field");
    check(pz2::jsonGetString(R"({"cmd":"host"})", "code").empty(), "json missing field");
    check(pz2::jsonQuote("Sam") == "\"Sam\"", "jsonQuote plain");
    check(pz2::jsonQuote("a\"b\\c\n") == "\"a\\\"b\\\\c \"", "jsonQuote escapes quote, backslash, control");
    check(pz2::jsonQuote(nullptr) == "\"\"", "jsonQuote null");
    {
        const auto b64 = [](const char* text) {
            return pz2::base64Encode(reinterpret_cast<const std::uint8_t*>(text), std::strlen(text));
        };
        check(b64("") == "" && b64("f") == "Zg==" && b64("fo") == "Zm8=" && b64("foo") == "Zm9v" &&
                  b64("foobar") == "Zm9vYmFy",
              "base64 RFC 4648 vectors");
        const std::uint8_t high[3] = {0xFF, 0xFE, 0xFD};
        check(pz2::base64Encode(high, 3) == "//79", "base64 high bytes");
    }
    {
        const std::string eAcute = "\xC3\xA9";
        const std::string straddle = std::string(63, 'x') + eAcute + "y"; // 2-byte char starts at byte 63
        check(pz2::jsonQuote(straddle.c_str()) == "\"" + std::string(63, 'x') + eAcute + "\"",
              "jsonQuote keeps a character that starts before the cap");
        const std::string after = std::string(64, 'x') + eAcute;
        check(pz2::jsonQuote(after.c_str()) == "\"" + std::string(64, 'x') + "\"", "jsonQuote cuts at the cap");
    }

    // SPSC: one producer, one consumer, strict FIFO, no loss.
    auto queue = std::make_unique<pz2::SPSCQueue<std::uint32_t, 1024>>();
    constexpr std::uint32_t kCount = 2'000'000;
    std::thread producer([&] {
        for (std::uint32_t i = 1; i <= kCount; ++i) {
            std::uint32_t v = i;
            while (!queue->push(std::move(v))) {
                std::this_thread::yield();
            }
        }
    });
    std::uint32_t expected = 1;
    bool ordered = true;
    while (expected <= kCount) {
        if (auto v = queue->pop()) {
            ordered = ordered && *v == expected;
            ++expected;
        }
    }
    producer.join();
    check(ordered, "spsc preserves order across threads");
    check(!queue->pop(), "spsc empty after drain");

    {
        pz2::RemoteApplyScope scope;
        check(pz2::g_IsApplyingRemoteAction.load(), "guard set inside scope");
    }
    check(!pz2::g_IsApplyingRemoteAction.load(), "guard cleared after scope");

    // File-bridge codec.
    check(pz2::jsonGetNumber(R"({"a": -1.5e2})", "a") == -150.0, "json number");
    check(!pz2::jsonGetNumber(R"({"a":"x"})", "a"), "json number rejects string");
    check(pz2::isSafeFileName("clip_3.bin") && !pz2::isSafeFileName("../x") && !pz2::isSafeFileName("a\\b") &&
              !pz2::isSafeFileName(".hidden"),
          "safe file names");
    {
        const auto line = pz2::parseLuaLine(R"(32 clip_1.bin {"k":1})");
        check(line && line->type == 32 && line->file == "clip_1.bin" && line->json == R"({"k":1})", "lua line parse");
        check(!pz2::parseLuaLine(R"(32 ..\evil {"k":1})"), "lua line rejects path");
        check(!pz2::parseLuaLine(R"(99 - {})"), "lua line rejects unknown type");
        const auto vpose = pz2::parseLuaLine(R"(19 - {"k":"vpose","x":1,"y":2,"z":3,"yaw":0.5,"pitch":0,"roll":0,"spd":4,"steer":0})");
        check(vpose && vpose->type == 0x13 && vpose->file.empty(), "lua line parses 0x13 vehicle pose");
        check(pz2::isKnownPacketType(0x13) && pz2::isUnreliable(pz2::PacketType::VEHICLE_POSE_20HZ) &&
                  pz2::fixedPayloadSize(pz2::PacketType::VEHICLE_POSE_20HZ) == 0 &&
                  !pz2::isEchoGuarded(pz2::PacketType::VEHICLE_POSE_20HZ),
              "0x13 VEHICLE_POSE_20HZ is known, unreliable, variable-size JSON, and not echo-guarded");
    }
    {
        const auto ledger = pz2::packFixed(pz2::PacketType::LEDGER_SYNC_1HZ, R"({"cash":123456,"cc":42,"speed":1,"tod":12.5})");
        check(ledger && ledger->size() == 1 + sizeof(pz2::LedgerSyncPayload), "ledger packs");
        if (ledger) {
            check(pz2::unpackFixed(pz2::PacketType::LEDGER_SYNC_1HZ, ledger->data() + 1, ledger->size() - 1) ==
                      R"({"cash":123456,"cc":42,"speed":1,"tod":12.5})",
                  "ledger round-trips");
        }
        check(!pz2::packFixed(pz2::PacketType::LEDGER_SYNC_1HZ, R"({"cash":1,"cc":1,"speed":9,"tod":1})"),
              "ledger rejects bad speed");
        check(pz2::fixedPayloadSize(pz2::PacketType::ACTION_DELETE_SPATIAL) == 0,
              "delete is a JSON packet (part name and peer flag survive the wire)");
        check(!pz2::packFixed(pz2::PacketType::CURSOR_TRANSFORM_20HZ, R"({"cx":1})"), "cursor needs all fields");
        const char* presence = R"({"cx":1.5,"cy":2,"cz":-3,"px":4,"py":5,"pz":6,"yaw":0.25,"m":2,"pitch":-0.375})";
        const auto cursor = pz2::packFixed(pz2::PacketType::CURSOR_TRANSFORM_20HZ, presence);
        check(cursor && cursor->size() == 1 + sizeof(pz2::CursorTransformPayload), "presence packs");
        if (cursor) {
            check(pz2::unpackFixed(pz2::PacketType::CURSOR_TRANSFORM_20HZ, cursor->data() + 1, cursor->size() - 1) ==
                      presence,
                  "presence round-trips with mode and pitch");
        }
        const auto cursorNoPitch = pz2::packFixed(
            pz2::PacketType::CURSOR_TRANSFORM_20HZ,
            R"({"cx":1.5,"cy":2,"cz":-3,"px":4,"py":5,"pz":6,"yaw":0.25,"m":2})");
        check(cursorNoPitch &&
                  pz2::unpackFixed(pz2::PacketType::CURSOR_TRANSFORM_20HZ, cursorNoPitch->data() + 1,
                                   cursorNoPitch->size() - 1) ==
                      R"({"cx":1.5,"cy":2,"cz":-3,"px":4,"py":5,"pz":6,"yaw":0.25,"m":2,"pitch":0})",
              "presence without pitch defaults to 0");
        check(!pz2::packFixed(pz2::PacketType::CURSOR_TRANSFORM_20HZ,
                              R"({"cx":1,"cy":2,"cz":3,"px":4,"py":5,"pz":6,"yaw":0,"m":7})"),
              "presence rejects bad mode");
        check(!pz2::packFixed(pz2::PacketType::CURSOR_TRANSFORM_20HZ,
                              R"({"cx":1,"cy":2,"cz":3,"px":4,"py":5,"pz":6,"yaw":0,"m":2,"pitch":9})"),
              "presence rejects out-of-range pitch");
    }

    // File bridge end to end in a temp folder: Lua hello + packet out, peer packet + save back in.
    {
        namespace fs = std::filesystem;
        const fs::path dir = fs::temp_directory_path() / "pz2coop_selftest";
        std::error_code ec;
        fs::remove_all(dir, ec);
        pz2::FileBridge bridge;
        check(bridge.open(dir) && fs::exists(dir / "bridge.txt"), "bridge opens");
        const auto writeText = [](const fs::path& p, std::string_view s) {
            std::ofstream(p, std::ios::binary).write(s.data(), static_cast<std::streamsize>(s.size()));
        };
        const auto readText = [](const fs::path& p) {
            std::ifstream in(p, std::ios::binary);
            return std::string(std::istreambuf_iterator<char>(in), {});
        };
        writeText(dir / "save.bin", std::string(600 * 1024, 'S'));
        writeText(dir / "out_1.txt", "{\"cmd\":\"hello\",\"sid\":\"t1\"}\n"
                                     "17 - {\"cash\":5,\"cc\":1,\"speed\":1,\"tod\":0}\n"
                                     "33 - {\"h\":0,\"x\":1,\"y\":2,\"z\":3,\"r\":250,\"k\":\"p\",\"n\":\"Rock_A\"}\n"
                                     "2 save.bin {}\n#end\n");
        const std::string deleteJson = "{\"h\":0,\"x\":1,\"y\":2,\"z\":3,\"r\":250,\"k\":\"p\",\"n\":\"Rock_A\"}";
        std::vector<std::string> sent;
        const auto t0 = pz2::FileBridge::Clock::now();
        bridge.poll([&](bool, std::string_view d) { sent.emplace_back(d); }, t0);
        check(bridge.alive() && !fs::exists(dir / "out_1.txt"), "hello accepted, out file consumed");
        check(sent.size() == 1 + 1 + 3 + 1 && sent[0].size() == 1 + sizeof(pz2::LedgerSyncPayload) &&
                  sent[1] == "\x21" + deleteJson && sent[2][0] == 2 && sent[5] == std::string_view("\x03{}", 3),
              "ledger + JSON delete (all fields kept) + 3 save chunks + commit");

        // Loop the host's packets back in as if they came from the peer.
        for (std::size_t i = 1; i < sent.size(); ++i) {
            pz2::NetMessage m{pz2::MsgKind::Packet, std::vector<std::uint8_t>(sent[i].begin(), sent[i].end())};
            bridge.forward(m);
        }
        const std::string place = std::string("\x20{\"g\":1}") + '\0' + "BLUEPRINT";
        bridge.forward({pz2::MsgKind::Packet, std::vector<std::uint8_t>(place.begin(), place.end())});
        bridge.forward({pz2::MsgKind::Json, std::vector<std::uint8_t>{'{', '}'}});
        bridge.poll([](bool, std::string_view) {}, t0 + std::chrono::milliseconds(50));
        const std::string in1 = readText(dir / "in_1.txt");
        check(in1 == "sid t1\n33 - " + deleteJson +
                         "\n{\"event\":\"save_progress\",\"got\":1,\"total\":3,\"bytes\":262144}"
                         "\n{\"event\":\"save_progress\",\"got\":2,\"total\":3,\"bytes\":524288}"
                         "\n{\"event\":\"save_progress\",\"got\":3,\"total\":3,\"bytes\":614400}"
                         "\n3 rx_save.bin {}\n32 rx_0.bin {\"g\":1}\n{}\n#end\n",
              "in file contents (delete arrives with its part name, save progress per chunk)");
        check(fs::file_size(dir / "rx_save.bin", ec) == 600 * 1024 && readText(dir / "rx_0.bin") == "BLUEPRINT",
              "save + attachment written");
        writeText(dir / "out_2.txt", "{\"cmd\":\"ack\",\"n\":\"1\"}\n#end\n");
        bridge.poll([](bool, std::string_view) {}, t0 + std::chrono::milliseconds(100));
        check(!fs::exists(dir / "in_1.txt"), "ack deletes in file");
        // A commit without its chunks tells the guest's UI instead of leaving it waiting.
        bridge.forward({pz2::MsgKind::Packet, std::vector<std::uint8_t>{0x03, '{', '}'}});
        bridge.poll([](bool, std::string_view) {}, t0 + std::chrono::milliseconds(150));
        check(readText(dir / "in_2.txt") == "sid t1\n{\"event\":\"error\",\"code\":\"zoo_transfer_failed\"}\n#end\n",
              "incomplete save reports zoo_transfer_failed");

        // 0x01 HANDSHAKE_HELLO forwards JSON metadata (mode, scenario, diff, wild, ver) and keeps empty hello.
        writeText(dir / "out_3.txt", "{\"cmd\":\"ack\",\"n\":\"2\"}\n#end\n");
        bridge.poll([](bool, std::string_view) {}, t0 + std::chrono::milliseconds(160));
        const std::string helloJson = R"({"mode":"ScenarioCareer","scenario":"Scenario_01","diff":"Default","wild":false,"ver":"0.4.0"})";
        std::vector<std::uint8_t> helloPkt{0x01};
        helloPkt.insert(helloPkt.end(), helloJson.begin(), helloJson.end());
        bridge.forward({pz2::MsgKind::Packet, std::vector<std::uint8_t>{0x01}});
        bridge.forward({pz2::MsgKind::Packet, helloPkt});
        // Malformed / control-char / oversize hello payloads must be dropped silently.
        bridge.forward({pz2::MsgKind::Packet, std::vector<std::uint8_t>{0x01, '{', '\n', '}'}});
        bridge.forward({pz2::MsgKind::Packet, std::vector<std::uint8_t>{0x01, 'b', 'a', 'd'}});
        std::vector<std::uint8_t> bigHello(2100, 'a');
        bigHello[0] = 0x01;
        bigHello[1] = '{';
        bigHello.back() = '}';
        bridge.forward({pz2::MsgKind::Packet, bigHello});
        bridge.poll([](bool, std::string_view) {}, t0 + std::chrono::milliseconds(200));
        check(readText(dir / "in_3.txt") == "sid t1\n1 - {}\n1 - " + helloJson + "\n#end\n",
              "HANDSHAKE_HELLO forwards valid JSON and rejects malformed/oversize payloads");

        bridge.poll([](bool, std::string_view) {}, t0 + std::chrono::seconds(30));
        check(!bridge.alive(), "silent Lua times out");
        fs::remove_all(dir, ec);
    }

    // Shared-table bridge: a fake Lua array (16-byte TValues, integer tag 0x13) in this process.
    {
        constexpr std::size_t kStride = 16;
        auto table = std::make_unique<std::uint8_t[]>(pz2::kMemTotalSlots * kStride + 64);
        std::uint8_t* base = table.get() + 16;
        const auto slot = [&](std::size_t i) -> std::int64_t* {
            return reinterpret_cast<std::int64_t*>(base + (i - 1) * kStride);
        };
        for (std::size_t i = 1; i <= pz2::kMemTotalSlots; ++i) {
            *slot(i) = 0;
            base[(i - 1) * kStride + 8] = 0x13;
        }
        for (std::int64_t i = 1; i <= 4; ++i) {
            *slot(static_cast<std::size_t>(i)) = pz2::kMemMagic + i;
        }
        *slot(7) = pz2::kMemVersion;
        const auto hit = pz2::findMemMagic(base, 4 * kStride + 8);
        check(hit.offset == 0 && hit.stride == kStride, "magic run + stride detected");

        namespace fs = std::filesystem;
        const fs::path dir = fs::temp_directory_path() / "pz2coop_selftest_mem";
        std::error_code ec;
        fs::remove_all(dir, ec);
        pz2::FileBridge protocol;
        protocol.open(dir);
        pz2::MemBridge mem;
        std::vector<std::string> delivered;
        const auto deliver = [&](bool, std::string_view d) { delivered.emplace_back(d); };
        auto now = pz2::MemBridge::Clock::now();
        for (int i = 0; i < 400 && !mem.connected(); ++i) {
            ++*slot(6);
            mem.poll(protocol, deliver, now);
            std::this_thread::sleep_for(std::chrono::milliseconds(25));
            now = pz2::MemBridge::Clock::now();
        }
        check(mem.connected() && *slot(5) != 0, "DLL discovers and claims the table");

        // Lua writes "hello" + a status command into its ring (padded to 8 bytes with '\n').
        std::string out = "{\"cmd\":\"hello\",\"sid\":\"m1\"}\n{\"cmd\":\"status\"}\n";
        out.append((8 - out.size() % 8) % 8, '\n');
        for (std::size_t i = 0; i < out.size() / 8; ++i) {
            std::memcpy(slot(17 + i), out.data() + i * 8, 8);
        }
        *slot(9) = static_cast<std::int64_t>(out.size() / 8);
        ++*slot(6);
        mem.poll(protocol, deliver, now);
        check(*slot(10) == *slot(9), "DLL consumed Lua ring");
        check(delivered.size() == 1 && delivered[0] == "{\"cmd\":\"status\"}", "hello handled, status delivered");

        protocol.forward({pz2::MsgKind::Json, std::vector<std::uint8_t>{'{', '"', 'e', '"', ':', '1', '}'}});
        ++*slot(6);
        mem.poll(protocol, deliver, now);
        std::string in;
        for (std::int64_t s = 0; s < *slot(11); ++s) {
            in.append(reinterpret_cast<const char*>(slot(17 + pz2::kMemRingSlots + static_cast<std::size_t>(s))), 8);
        }
        check(in == "{\"e\":1}\n", "DLL wrote event into Lua ring");
        check(base[8] == 0x13 && base[(17 + pz2::kMemRingSlots - 1) * kStride + 8] == 0x13, "type tags preserved");
        fs::remove_all(dir, ec);
    }

    // UI overlay pieces (the full build is checked against the game by tools/test_ui_overlay.py).
    {
        const char* wiki = "Wikipedia";
        check(pz2::adler32(reinterpret_cast<const std::uint8_t*>(wiki), 9) == 0x11E60398, "adler32 known value");
        check(pz2::stripSourceMap("a;\n//# sourceMappingURL=data:x\n") == "a;\n", "source map line stripped");
        check(pz2::stripSourceMap("a;\n//# sourceMappingURL=x\nb;") == "a;\n//# sourceMappingURL=x\nb;",
              "non-trailing source map kept");
        const std::string vanilla = "import x;\nfoo(1);\n    bar(2);\nbaz(3);\n";
        const std::string patch = "// comment\nimport { y } from 'y';\n@@ after foo(1);\nA();\n@@ before bar(2);\n"
                                  "B();\n\n@@ replace baz(3)\nqux(4)\n";
        std::string out, error;
        check(pz2::applyAnchorPatch(vanilla, patch, out, error), "anchor patch applies");
        check(out == "import { y } from 'y';\nimport x;\nfoo(1);\nA();\n    B();\n    bar(2);\nqux(4);\n",
              "anchor patch result matches build_ovl_mod.apply_patch");
        check(!pz2::applyAnchorPatch(vanilla, "@@ after nothere\nX\n", out, error), "missing anchor fails");
        check(!pz2::applyAnchorPatch("a a", "@@ replace a\nX\n", out, error), "duplicate anchor fails");
        check(!pz2::applyAnchorPatch(vanilla, "@@ sideways foo\nX\n", out, error), "bad mode fails");
    }

    // Security & fuzz checks (docs/RELEASE_CHECKLIST.md): malformed, out-of-range, oversize, path traversal.
    {
        check(!pz2::isSafeFileName(""), "empty filename rejected");
        check(!pz2::isSafeFileName(std::string(65, 'a')), "oversize filename rejected");
        check(!pz2::isSafeFileName("sub/clip.bin"), "forward slash rejected");
        check(!pz2::isSafeFileName("C:\\Windows\\win.ini"), "drive path rejected");
        check(!pz2::parseLuaLine("32 - not_json"), "non-object JSON rejected");
        check(!pz2::parseLuaLine("32"), "truncated lua line rejected");
        check(!pz2::packFixed(pz2::PacketType::CURSOR_TRANSFORM_20HZ,
                              R"({"cx":0,"cy":0,"cz":0,"px":0,"py":0,"pz":0,"yaw":0,"m":9})"),
              "cursor mode out of range rejected");
        check(!pz2::packFixed(pz2::PacketType::LEDGER_SYNC_1HZ,
                              R"({"cash":0,"cc":0,"speed":5,"tod":12})"),
              "ledger speed out of range rejected");
        check(!pz2::packFixed(pz2::PacketType::LEDGER_SYNC_1HZ,
                              R"({"cash":0,"cc":0,"speed":1,"tod":25})"),
              "ledger tod out of range rejected");
        const std::uint8_t badPayload[4] = {1, 2, 3, 4};
        check(pz2::unpackFixed(pz2::PacketType::CURSOR_TRANSFORM_20HZ, badPayload, sizeof(badPayload)).empty(),
              "truncated cursor payload rejected");
        check(pz2::unpackFixed(pz2::PacketType::LEDGER_SYNC_1HZ, badPayload, sizeof(badPayload)).empty(),
              "truncated ledger payload rejected");
        pz2::CursorTransformPayload nanCursor{};
        nanCursor.cam_pos[0] = std::numeric_limits<float>::quiet_NaN();
        check(pz2::unpackFixed(pz2::PacketType::CURSOR_TRANSFORM_20HZ,
                               reinterpret_cast<const std::uint8_t*>(&nanCursor), sizeof(nanCursor))
                  .empty(),
              "NaN cursor payload rejected");
    }

    // LZ4 compression & fuzz checks (docs/NETWORK_PROTOCOL.md kFlagLz4).
    {
        // Repetitive 256 KiB save-like chunk compresses strongly and round-trips bit-identically.
        std::vector<std::uint8_t> saveChunk(256 * 1024);
        for (std::size_t i = 0; i < saveChunk.size(); ++i) {
            saveChunk[i] = static_cast<std::uint8_t>((i / 17) ^ ((i % 64) * 3));
        }
        const auto compressed = pz2::lz4CompressPayload(saveChunk.data(), saveChunk.size());
        check(compressed.has_value() && compressed->size() < saveChunk.size() / 2, "lz4 compresses save chunk >2x");
        if (compressed) {
            const auto plain = pz2::lz4DecompressPayload(compressed->data(), compressed->size(), pz2::kMaxPayloadSize);
            check(plain.has_value() && *plain == saveChunk, "lz4 save chunk round-trips bit-identically");
        }
        // Short literal-only block + overlapping RLE run.
        const std::vector<std::uint8_t> shortData = {'P', 'Z', '2', 'C', 'o', 'o', 'p'};
        const auto shortBlock = pz2::lz4CompressBlock(shortData.data(), shortData.size());
        const auto shortOut = pz2::lz4DecompressBlock(shortBlock.data(), shortBlock.size(), shortData.size());
        check(shortOut.has_value() && *shortOut == shortData, "lz4 short literal block round-trips");

        const std::vector<std::uint8_t> rle(4096, 0x5A);
        const auto rleComp = pz2::lz4CompressPayload(rle.data(), rle.size());
        check(rleComp.has_value() && rleComp->size() < 64, "lz4 RLE run compresses tightly");
        if (rleComp) {
            const auto rleOut = pz2::lz4DecompressPayload(rleComp->data(), rleComp->size(), pz2::kMaxPayloadSize);
            check(rleOut.has_value() && *rleOut == rle, "lz4 overlapping RLE round-trips");
        }
        // Fuzz malformed / malicious LZ4 payloads: truncated, oversize header (zip bomb), zero offset, overrun.
        const std::uint8_t tiny[2] = {1, 2};
        check(!pz2::lz4DecompressPayload(tiny, sizeof(tiny), pz2::kMaxPayloadSize).has_value(),
              "lz4 rejects <4-byte header");
        const std::uint8_t bomb[8] = {0xFF, 0xFF, 0xFF, 0x7F, 0x10, 'A', 0x01, 0x00};
        check(!pz2::lz4DecompressPayload(bomb, sizeof(bomb), pz2::kMaxPayloadSize).has_value(),
              "lz4 rejects oversize uncompressed length");
        const std::uint8_t zeroOff[8] = {16, 0, 0, 0, 0x10, 'A', 0x00, 0x00};
        check(!pz2::lz4DecompressPayload(zeroOff, sizeof(zeroOff), pz2::kMaxPayloadSize).has_value(),
              "lz4 rejects zero match offset");
        const std::uint8_t badOff[8] = {16, 0, 0, 0, 0x10, 'A', 0x05, 0x00};
        check(!pz2::lz4DecompressPayload(badOff, sizeof(badOff), pz2::kMaxPayloadSize).has_value(),
              "lz4 rejects out-of-bounds match offset");
        const std::uint8_t truncLit[6] = {10, 0, 0, 0, 0x50, 'A'};
        check(!pz2::lz4DecompressPayload(truncLit, sizeof(truncLit), pz2::kMaxPayloadSize).has_value(),
              "lz4 rejects truncated literals");
    }

    // Vehicle forced-boundary AOB patcher checks (unique match, patch, restore, ambiguity rejection).
    {
        std::vector<std::uint8_t> buf(64, 0x90);
        const std::uint8_t sig[13] = {0x45, 0x38, 0x81, 0xF1, 0x00, 0x00, 0x00, 0x0F, 0x85, 0x3F, 0x06, 0x00, 0x00};
        std::memcpy(buf.data() + 16, sig, sizeof(sig));
        check(pz2::patchVehicleBoundsInBuffer(buf.data(), buf.size(), true), "vehicle patch applies to unique sig");
        check(buf[23] == 0x90 && buf[24] == 0xE9 && buf[25] == 0x3F && buf[26] == 0x06, "vehicle patch writes nop+jmp");
        check(pz2::patchVehicleBoundsInBuffer(buf.data(), buf.size(), false), "vehicle patch restores jne");
        check(buf[23] == 0x0F && buf[24] == 0x85 && buf[25] == 0x3F && buf[26] == 0x06, "vehicle patch restores bytes");
        // Duplicate signature must be rejected cleanly.
        std::memcpy(buf.data() + 40, sig, sizeof(sig));
        check(!pz2::patchVehicleBoundsInBuffer(buf.data(), buf.size(), true), "vehicle patch rejects ambiguous sig");
        // Missing signature must be rejected cleanly.
        std::vector<std::uint8_t> empty(64, 0xCC);
        check(!pz2::patchVehicleBoundsInBuffer(empty.data(), empty.size(), true), "vehicle patch rejects missing sig");
    }

    std::printf("selftest: %d check(s) failed\n", g_failures);
    return g_failures == 0 ? 0 : 1;
}
