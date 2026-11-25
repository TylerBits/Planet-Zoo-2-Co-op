// Runtime UI-overlay build; see ui_overlay.hpp. OVL layout: tools/cobra-tools/source/formats/ovl/ovl.xml
// (version 20; PZ2 ships user_version 8724 = Oodle, our template is 8340 = zlib).
#include "ui_overlay.hpp"

#include <windows.h>

#include <atomic>
#include <cwctype>
#include <cstring>
#include <fstream>
#include <iterator>
#include <map>
#include <optional>
#include <thread>
#include <unordered_map>

#include "diag.hpp"

namespace pz2 {
namespace {

constexpr std::size_t kFixedHeader = 144;
constexpr std::size_t kArchiveEntry = 68;
constexpr std::uint32_t kCompressionZlib = 1;
constexpr std::uint32_t kCompressionOodle = 4;
constexpr char kSlotTag[] = "/*PZ2COOP_SLOT ";
// Bump when the build logic changes, so cached outputs from an older DLL are rebuilt.
constexpr char kStampVersion[] = "pz2coop-ui-1";

HANDLE g_buildDone = nullptr; // manual-reset event, set when the build thread has finished (ok or not)
std::atomic<bool> g_waitLogged{false};

using Bytes = std::vector<std::uint8_t>;

std::optional<Bytes> readFile(const std::filesystem::path& path) {
    std::ifstream in(path, std::ios::binary);
    if (!in) {
        return std::nullopt;
    }
    return Bytes(std::istreambuf_iterator<char>(in), std::istreambuf_iterator<char>());
}

template <typename T>
bool readAt(const Bytes& b, std::size_t at, T& out) {
    if (at > b.size() || b.size() - at < sizeof(T)) {
        return false;
    }
    std::memcpy(&out, b.data() + at, sizeof(T));
    return true;
}

struct Archive {
    std::size_t entryOffset = 0;
    std::uint32_t numPools = 0, numDatas = 0, numPoolGroups = 0, numBufferGroups = 0, numBuffers = 0;
    std::uint32_t numFragments = 0, numRootEntries = 0, setDataSize = 0, compressedSize = 0;
    std::uint64_t uncompressedSize = 0;
};

struct Header {
    std::uint32_t compression = 0;
    std::size_t eof = 0; // end of the OVL header = start of the STATIC archive
    Archive staticArchive;
};

bool parseHeader(const Bytes& ovl, Header& h, std::string& error) {
    std::uint32_t userVersion = 0;
    if (ovl.size() < kFixedHeader || std::memcmp(ovl.data(), "FRES", 4) != 0 || ovl[5] != 20 ||
        !readAt(ovl, 8, userVersion)) {
        error = "not an OVL v20 file";
        return false;
    }
    std::uint32_t lenNames = 0, numAux = 0, numFiles = 0, numDeps = 0, numArchives = 0;
    std::uint16_t numIncluded = 0, numMimes = 0;
    std::uint32_t numStreamFiles = 0, lenArchiveNames = 0, numTriplets = 0;
    readAt(ovl, 16, lenNames);
    readAt(ovl, 24, numAux);
    readAt(ovl, 28, numIncluded);
    readAt(ovl, 30, numMimes);
    readAt(ovl, 32, numFiles);
    readAt(ovl, 40, numDeps);
    readAt(ovl, 44, numArchives);
    readAt(ovl, 64, numStreamFiles);
    readAt(ovl, 80, lenArchiveNames);
    readAt(ovl, 92, numTriplets);
    std::size_t pos = kFixedHeader + lenNames + std::size_t{numMimes} * 32;
    pos += std::size_t{numTriplets} * 3;
    pos += (4 - (std::size_t{numTriplets} * 3) % 4) % 4;
    pos += std::size_t{numFiles} * 12 + lenArchiveNames;
    if (numArchives == 0 || pos + kArchiveEntry > ovl.size()) {
        error = "OVL has no archive";
        return false;
    }
    Archive& a = h.staticArchive;
    a.entryOffset = pos;
    std::uint16_t numDatas = 0, numPoolGroups = 0;
    readAt(ovl, pos + 12, a.numPools);
    readAt(ovl, pos + 16, numDatas);
    readAt(ovl, pos + 18, numPoolGroups);
    a.numDatas = numDatas;
    a.numPoolGroups = numPoolGroups;
    readAt(ovl, pos + 20, a.numBufferGroups);
    readAt(ovl, pos + 24, a.numBuffers);
    readAt(ovl, pos + 28, a.numFragments);
    readAt(ovl, pos + 32, a.numRootEntries);
    readAt(ovl, pos + 40, a.setDataSize);
    readAt(ovl, pos + 44, a.compressedSize);
    readAt(ovl, pos + 48, a.uncompressedSize);
    pos += std::size_t{numArchives} * kArchiveEntry + std::size_t{numIncluded} * 4 + std::size_t{numDeps} * 20 +
           std::size_t{numAux} * 12 + std::size_t{numStreamFiles} * 12 + std::size_t{numArchives} * 8;
    h.compression = (userVersion >> 7) & 7;
    h.eof = pos;
    if (h.eof > ovl.size() || ovl.size() - h.eof < a.compressedSize) {
        error = "OVL archive runs past the end of the file";
        return false;
    }
    return true;
}

using OodleDecompress = std::int64_t(__stdcall*)(const void*, std::int64_t, void*, std::int64_t, int, int, int, void*,
                                                 std::int64_t, void*, void*, void*, std::int64_t, int);

bool oodleDecompress(const std::filesystem::path& dll, const std::uint8_t* src, std::size_t srcSize, Bytes& out,
                     std::string& error) {
    // The game ships and loads this DLL itself; this just takes another reference.
    HMODULE module = LoadLibraryW(dll.c_str());
    const auto fn = module != nullptr
                        ? reinterpret_cast<OodleDecompress>(GetProcAddress(module, "OodleLZ_Decompress"))
                        : nullptr;
    if (fn == nullptr) {
        error = "oo2core_9_win64.dll / OodleLZ_Decompress not found";
        return false;
    }
    const std::int64_t got = fn(src, static_cast<std::int64_t>(srcSize), out.data(),
                                static_cast<std::int64_t>(out.size()), 0, 0, 0, nullptr, 0, nullptr, nullptr, nullptr,
                                0, 3);
    if (got != static_cast<std::int64_t>(out.size())) {
        error = "Oodle decompression failed";
        return false;
    }
    return true;
}

// ppuipkg file entries are {file_name ptr, file_size u64, file_content ptr}. Pointers are fragments
// (link pool/offset -> target pool/offset): a fragment whose target is one of our path strings is a file_name
// slot, so that file's size sits 8 bytes later and its content pointer 16 bytes later.
bool findPpuipkgFiles(const Archive& a, const Bytes& data, const std::vector<std::string>& paths,
                      std::map<std::string, std::string>& found, std::string& error) {
    std::size_t pos = std::size_t{a.numPoolGroups} * 4;
    const std::size_t poolsHeader = pos;
    pos += std::size_t{a.numPools} * 32 + std::size_t{a.numDatas} * 32 + std::size_t{a.numBuffers} * 8 +
           std::size_t{a.numBufferGroups} * 32 + std::size_t{a.numRootEntries} * 16;
    const std::size_t fragmentsAt = pos;
    pos += std::size_t{a.numFragments} * 16 + a.setDataSize;
    std::vector<std::size_t> poolStart;
    for (std::uint32_t i = 0; i < a.numPools; ++i) {
        std::uint32_t size = 0;
        if (!readAt(data, poolsHeader + std::size_t{i} * 32 + 8, size)) {
            error = "pool table truncated";
            return false;
        }
        poolStart.push_back(pos);
        pos += size;
    }
    if (pos > data.size()) {
        error = "pools run past the archive";
        return false;
    }
    auto address = [&](std::int32_t pool, std::uint32_t offset) -> std::optional<std::size_t> {
        if (pool < 0 || static_cast<std::size_t>(pool) >= poolStart.size()) {
            return std::nullopt;
        }
        return poolStart[static_cast<std::size_t>(pool)] + offset;
    };
    std::unordered_map<std::uint64_t, std::pair<std::int32_t, std::uint32_t>> links;
    struct NameHit {
        std::string path;
        std::int32_t pool;
        std::uint32_t offset;
    };
    std::vector<NameHit> hits;
    for (std::uint32_t i = 0; i < a.numFragments; ++i) {
        std::int32_t lp = 0, sp = 0;
        std::uint32_t lo = 0, so = 0;
        const std::size_t f = fragmentsAt + std::size_t{i} * 16;
        if (!readAt(data, f, lp) || !readAt(data, f + 4, lo) || !readAt(data, f + 8, sp) ||
            !readAt(data, f + 12, so)) {
            error = "fragment table truncated";
            return false;
        }
        links[(std::uint64_t(std::uint32_t(lp)) << 32) | lo] = {sp, so};
        const auto at = address(sp, so);
        if (!at) {
            continue;
        }
        for (const std::string& path : paths) {
            const std::string key = "UIGameface/" + path;
            if (*at + key.size() + 1 <= data.size() && std::memcmp(data.data() + *at, key.data(), key.size()) == 0 &&
                data[*at + key.size()] == 0) {
                hits.push_back({path, lp, lo});
            }
        }
    }
    for (const NameHit& hit : hits) {
        const auto content = links.find((std::uint64_t(std::uint32_t(hit.pool)) << 32) | (hit.offset + 16));
        const auto entry = address(hit.pool, hit.offset);
        std::uint64_t size = 0;
        if (content == links.end() || !entry || !readAt(data, *entry + 8, size)) {
            continue;
        }
        const auto at = address(content->second.first, content->second.second);
        if (!at || *at > data.size() || data.size() - *at < size) {
            continue;
        }
        found[hit.path] = std::string(reinterpret_cast<const char*>(data.data() + *at), static_cast<std::size_t>(size));
    }
    for (const std::string& path : paths) {
        if (!found.count(path)) {
            error = "vanilla UI file not found in the game: " + path;
            return false;
        }
    }
    return true;
}

struct Segment {
    std::size_t filePos, dataPos, length;
};

bool storedSegments(const Bytes& file, std::size_t start, std::size_t size, std::vector<Segment>& segs) {
    std::size_t pos = start + 2, out = 0;
    const std::size_t end = start + size;
    while (pos + 5 <= end) {
        const std::uint8_t head = file[pos];
        std::uint16_t len = 0, nlen = 0;
        readAt(file, pos + 1, len);
        readAt(file, pos + 3, nlen);
        if ((head & ~1u) != 0 || (len ^ nlen) != 0xFFFF || pos + 5 + len > end) {
            return false;
        }
        segs.push_back({pos + 5, out, len});
        pos += 5 + std::size_t{len};
        out += len;
        if (head & 1) {
            return pos + 4 == end; // adler32 follows the last block
        }
    }
    return false;
}

struct Slot {
    std::size_t at, size;
    int index;
    std::string path;
};

std::vector<Slot> findSlots(const Bytes& data) {
    std::vector<Slot> slots;
    const std::string_view text(reinterpret_cast<const char*>(data.data()), data.size());
    std::size_t at = 0;
    while ((at = text.find(kSlotTag, at)) != std::string_view::npos) {
        const std::size_t close = text.find("*/", at);
        if (close == std::string_view::npos) {
            break;
        }
        const std::string body(text.substr(at + sizeof(kSlotTag) - 1, close - at - (sizeof(kSlotTag) - 1)));
        int index = -1;
        unsigned long long size = 0;
        char path[512] = {};
        if (sscanf_s(body.c_str(), "%d %llu %511s", &index, &size, path, static_cast<unsigned>(sizeof(path))) == 3 &&
            index >= 0 && size > 0 && at + size <= data.size()) {
            slots.push_back({at, static_cast<std::size_t>(size), index, path});
            at += static_cast<std::size_t>(size);
        } else {
            at = close;
        }
    }
    return slots;
}

std::string fileStamp(const std::filesystem::path& path) {
    std::error_code ec;
    const auto size = std::filesystem::file_size(path, ec);
    const auto time = std::filesystem::last_write_time(path, ec);
    return path.filename().string() + ":" + std::to_string(ec ? 0 : size) + ":" +
           std::to_string(ec ? 0 : time.time_since_epoch().count()) + "\n";
}

bool writeFileAtomic(const std::filesystem::path& path, const void* data, std::size_t size) {
    const std::filesystem::path tmp = path.wstring() + L".tmp";
    {
        std::ofstream out(tmp, std::ios::binary | std::ios::trunc);
        out.write(static_cast<const char*>(data), static_cast<std::streamsize>(size));
        if (!out) {
            return false;
        }
    }
    return MoveFileExW(tmp.c_str(), path.c_str(), MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH) != 0;
}

bool build(const std::filesystem::path& gameDir, const std::filesystem::path& uiDir, bool useCache,
           std::string& error) {
    const auto vanillaPath = gameDir / L"Win64" / L"ovldata" / L"GameMain" / L"Content" /
                             L"UserInterfaceEssentials.ovl";
    const auto templatePath = uiDir / L"PZ2CoopUI.template";
    const auto outPath = uiDir / L"PZ2CoopUI.ovl";
    const auto stampPath = uiDir / L"PZ2CoopUI.stamp";

    auto templ = readFile(templatePath);
    if (!templ) {
        error = "missing " + templatePath.filename().string() + " (reinstall the mod)";
        return false;
    }
    Header th;
    if (!parseHeader(*templ, th, error)) {
        error = "template: " + error;
        return false;
    }
    if (th.compression != kCompressionZlib) {
        error = "template is not a zlib OVL";
        return false;
    }
    std::vector<Segment> segs;
    if (!storedSegments(*templ, th.eof, th.staticArchive.compressedSize, segs)) {
        error = "template archive is not stored zlib";
        return false;
    }
    Bytes data(static_cast<std::size_t>(th.staticArchive.uncompressedSize));
    for (const Segment& s : segs) {
        if (s.dataPos + s.length > data.size()) {
            error = "template archive size mismatch";
            return false;
        }
        std::memcpy(data.data() + s.dataPos, templ->data() + s.filePos, s.length);
    }
    const std::vector<Slot> slots = findSlots(data);
    if (slots.empty()) {
        error = "template has no slots";
        return false;
    }

    std::string stamp = std::string(kStampVersion) + "\n" + fileStamp(vanillaPath) + fileStamp(templatePath);
    std::vector<std::string> paths;
    std::map<int, std::string> patches;
    for (const Slot& slot : slots) {
        const auto patchPath = uiDir / ("patch" + std::to_string(slot.index) + ".js");
        auto patch = readFile(patchPath);
        if (!patch) {
            error = "missing " + patchPath.filename().string() + " (reinstall the mod)";
            return false;
        }
        patches[slot.index] = std::string(patch->begin(), patch->end());
        paths.push_back(slot.path);
        stamp += fileStamp(patchPath);
    }
    if (useCache && std::filesystem::exists(outPath)) {
        if (auto old = readFile(stampPath); old && std::string(old->begin(), old->end()) == stamp) {
            diagLog("ui overlay: up to date (cached)");
            return true;
        }
    }

    auto vanilla = readFile(vanillaPath);
    if (!vanilla) {
        error = "can't read " + vanillaPath.string();
        return false;
    }
    Header vh;
    if (!parseHeader(*vanilla, vh, error)) {
        error = "game UI package: " + error;
        return false;
    }
    if (vh.compression != kCompressionOodle) {
        error = "game UI package is not Oodle compressed (game update?)";
        return false;
    }
    Bytes archive(static_cast<std::size_t>(vh.staticArchive.uncompressedSize));
    if (!oodleDecompress(gameDir / L"oo2core_9_win64.dll", vanilla->data() + vh.eof, vh.staticArchive.compressedSize,
                         archive, error)) {
        return false;
    }
    vanilla.reset();
    std::map<std::string, std::string> files;
    if (!findPpuipkgFiles(vh.staticArchive, archive, paths, files, error)) {
        return false;
    }
    archive.clear();
    archive.shrink_to_fit();

    for (const Slot& slot : slots) {
        std::string patched;
        if (!applyAnchorPatch(stripSourceMap(files[slot.path]), patches[slot.index], patched, error)) {
            error = slot.path + ": " + error;
            return false;
        }
        if (patched.size() > slot.size) {
            error = slot.path + ": patched file larger than its slot";
            return false;
        }
        std::memcpy(data.data() + slot.at, patched.data(), patched.size());
        std::memset(data.data() + slot.at + patched.size(), ' ', slot.size - patched.size());
    }
    for (const Segment& s : segs) {
        std::memcpy(templ->data() + s.filePos, data.data() + s.dataPos, s.length);
    }
    const std::uint32_t sum = adler32(data.data(), data.size());
    const std::size_t sumAt = th.eof + th.staticArchive.compressedSize - 4;
    const std::uint8_t be[4] = {std::uint8_t(sum >> 24), std::uint8_t(sum >> 16), std::uint8_t(sum >> 8),
                                std::uint8_t(sum)};
    std::memcpy(templ->data() + sumAt, be, 4);
    if (!writeFileAtomic(outPath, templ->data(), templ->size())) {
        error = "can't write " + outPath.string();
        return false;
    }
    writeFileAtomic(stampPath, stamp.data(), stamp.size());
    diagLog("ui overlay: built from the game's UI package (" + std::to_string(slots.size()) + " patched files)");
    return true;
}

} // namespace

std::uint32_t adler32(const std::uint8_t* data, std::size_t size) {
    std::uint32_t a = 1, b = 0;
    while (size > 0) {
        const std::size_t n = size < 5552 ? size : 5552;
        for (std::size_t i = 0; i < n; ++i) {
            a += data[i];
            b += a;
        }
        a %= 65521;
        b %= 65521;
        data += n;
        size -= n;
    }
    return (b << 16) | a;
}

std::string stripSourceMap(std::string_view js) {
    const std::size_t at = js.rfind("\n//# sourceMappingURL=");
    if (at == std::string_view::npos) {
        return std::string(js);
    }
    std::size_t lineEnd = js.find('\n', at + 1);
    if (lineEnd == std::string_view::npos) {
        lineEnd = js.size();
    }
    if (js.find_first_not_of(" \t\r\n\f\v", lineEnd) != std::string_view::npos) {
        return std::string(js); // not the trailing line
    }
    return std::string(js.substr(0, at)) + "\n";
}

// Port of apply_patch in tools/build_ovl_mod.py: "import " lines before the first section are hoisted to the
// top; "@@ before|after|replace <anchor>" sections apply at an anchor that must occur exactly once.
bool applyAnchorPatch(std::string_view vanilla, std::string_view patch, std::string& out, std::string& error) {
    struct Section {
        std::string mode, anchor;
        std::vector<std::string> body;
    };
    std::vector<std::string> imports;
    std::vector<Section> sections;
    std::size_t pos = 0;
    while (pos <= patch.size()) {
        std::size_t end = patch.find('\n', pos);
        if (end == std::string_view::npos) {
            end = patch.size();
        }
        std::string line(patch.substr(pos, end - pos));
        if (!line.empty() && line.back() == '\r') {
            line.pop_back();
        }
        const bool last = end == patch.size();
        if (!(last && line.empty())) {
            if (line.rfind("@@ ", 0) == 0) {
                const std::size_t space = line.find(' ', 3);
                Section s;
                s.mode = line.substr(3, space == std::string::npos ? std::string::npos : space - 3);
                s.anchor = space == std::string::npos ? "" : line.substr(space + 1);
                if ((s.mode != "before" && s.mode != "after" && s.mode != "replace") || s.anchor.empty()) {
                    error = "bad section header: " + line;
                    return false;
                }
                sections.push_back(std::move(s));
            } else if (!sections.empty()) {
                sections.back().body.push_back(line);
            } else if (line.rfind("import ", 0) == 0) {
                imports.push_back(line);
            }
        }
        pos = end + 1;
    }
    std::string text(vanilla);
    for (const Section& s : sections) {
        const std::size_t at = text.find(s.anchor);
        if (at == std::string::npos || text.find(s.anchor, at + 1) != std::string::npos) {
            error = "anchor not found exactly once (game UI changed?): " + s.anchor;
            return false;
        }
        std::string insert;
        for (std::size_t i = 0; i < s.body.size(); ++i) {
            insert += (i ? "\n" : "") + s.body[i];
        }
        const std::size_t keep = insert.find_last_not_of(" \t\r\n\f\v");
        insert.resize(keep == std::string::npos ? 0 : keep + 1);
        if (s.mode == "replace") {
            text = text.substr(0, at) + insert + text.substr(at + s.anchor.size());
        } else if (s.mode == "after") {
            const std::size_t where = at + s.anchor.size();
            text = text.substr(0, where) + "\n" + insert + text.substr(where);
        } else {
            const std::size_t nl = text.rfind('\n', at == 0 ? 0 : at - 1);
            const std::size_t lineStart = (at == 0 || nl == std::string::npos) ? 0 : nl + 1;
            const std::string lead = text.substr(lineStart, at - lineStart);
            const bool blank = lead.find_first_not_of(" \t\r\n\f\v") == std::string::npos;
            text = text.substr(0, at) + insert + "\n" + (blank ? lead : "") + text.substr(at);
        }
    }
    out.clear();
    for (const std::string& line : imports) {
        out += line + "\n";
    }
    out += text;
    return true;
}

bool buildUiOverlay(const std::filesystem::path& gameDir, const std::filesystem::path& packUiDir, bool useCache,
                    std::string& error) {
    try {
        if (build(gameDir, packUiDir, useCache, error)) {
            return true;
        }
    } catch (const std::exception& e) {
        error = std::string("exception: ") + e.what();
    }
    // A stale overlay from an older game version would shadow the new game's files: remove it.
    std::error_code ec;
    std::filesystem::remove(packUiDir / L"PZ2CoopUI.ovl", ec);
    std::filesystem::remove(packUiDir / L"PZ2CoopUI.stamp", ec);
    return false;
}

void startUiOverlayBuild() {
    g_buildDone = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    std::thread([] {
        wchar_t path[MAX_PATH] = {};
        const DWORD len = GetModuleFileNameW(nullptr, path, MAX_PATH);
        const std::filesystem::path gameDir = std::filesystem::path(std::wstring(path, len)).parent_path();
        std::string error;
        if (!buildUiOverlay(gameDir, gameDir / L"Win64" / L"ovldata" / L"PZ2Coop" / L"UI", true, error)) {
            diagLog("ui overlay: FAILED, co-op menus disabled: " + error);
        }
        if (g_buildDone != nullptr) {
            SetEvent(g_buildDone);
        }
    }).detach();
}

void waitForUiOverlayIfOurs(const wchar_t* path) {
    if (g_buildDone == nullptr || path == nullptr) {
        return;
    }
    std::wstring lower(path);
    for (wchar_t& c : lower) {
        c = static_cast<wchar_t>(std::towlower(c));
    }
    if (lower.find(L"pz2coopui.ovl") == std::wstring::npos) {
        return;
    }
    if (WaitForSingleObject(g_buildDone, 20000) != WAIT_OBJECT_0 && !g_waitLogged.exchange(true)) {
        diagLog("ui overlay: game opened PZ2CoopUI.ovl before the build finished (20 s)");
    }
}

} // namespace pz2
