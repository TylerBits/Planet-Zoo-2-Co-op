#pragma once

// Minimal, zero-dependency, bounds-checked LZ4 block codec (standard LZ4 block format) for PZ2-Coop.
// Wire format when PacketHeader::flags has kFlagLz4 (bit 0) set:
//   [uint32_t little-endian uncompressed_size][LZ4 compressed block bytes...]
// Every pointer arithmetic step is bounds-checked against untrusted network data.

#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <optional>
#include <vector>

namespace pz2 {

namespace detail {

constexpr std::size_t kLz4HashLog = 14;
constexpr std::size_t kLz4HashSize = 1u << kLz4HashLog;
constexpr std::size_t kLz4MinMatch = 4;
constexpr std::size_t kLz4LastLiterals = 5;
constexpr std::size_t kLz4MfLimit = 12;
constexpr std::size_t kLz4MaxDistance = 65535;

inline std::uint32_t readU32LE(const std::uint8_t* p) {
    return static_cast<std::uint32_t>(p[0]) | (static_cast<std::uint32_t>(p[1]) << 8) |
           (static_cast<std::uint32_t>(p[2]) << 16) | (static_cast<std::uint32_t>(p[3]) << 24);
}

inline void writeU32LE(std::uint8_t* p, std::uint32_t v) {
    p[0] = static_cast<std::uint8_t>(v & 0xFFu);
    p[1] = static_cast<std::uint8_t>((v >> 8) & 0xFFu);
    p[2] = static_cast<std::uint8_t>((v >> 16) & 0xFFu);
    p[3] = static_cast<std::uint8_t>((v >> 24) & 0xFFu);
}

inline std::uint32_t lz4Hash4(const std::uint8_t* p) {
    return (readU32LE(p) * 2654435761u) >> (32u - kLz4HashLog);
}

inline void emitLen(std::vector<std::uint8_t>& out, std::size_t len) {
    while (len >= 255) {
        out.push_back(255);
        len -= 255;
    }
    out.push_back(static_cast<std::uint8_t>(len));
}

} // namespace detail

// Compresses src[0..srcSize) into standard LZ4 block format.
inline std::vector<std::uint8_t> lz4CompressBlock(const std::uint8_t* src, std::size_t srcSize) {
    std::vector<std::uint8_t> out;
    if (src == nullptr || srcSize == 0) {
        return out;
    }
    out.reserve(srcSize + srcSize / 255 + 16);

    if (srcSize < detail::kLz4MfLimit) {
        const std::uint8_t token = static_cast<std::uint8_t>(std::min<std::size_t>(srcSize, 15) << 4);
        out.push_back(token);
        if (srcSize >= 15) {
            detail::emitLen(out, srcSize - 15);
        }
        out.insert(out.end(), src, src + srcSize);
        return out;
    }

    std::array<std::uint32_t, detail::kLz4HashSize> table{};
    table.fill(0xFFFFFFFFu);

    const std::size_t mflimit = srcSize - detail::kLz4MfLimit;
    const std::size_t matchlimit = srcSize - detail::kLz4LastLiterals;
    std::size_t ip = 0;
    std::size_t anchor = 0;

    table[detail::lz4Hash4(src)] = 0;
    ++ip;

    while (ip <= mflimit) {
        std::size_t matchPos = 0;
        bool found = false;
        std::size_t step = 1;
        std::size_t searchMatchNb = 1u << 6;

        while (ip <= mflimit) {
            const std::uint32_t h = detail::lz4Hash4(src + ip);
            const std::uint32_t ref = table[h];
            table[h] = static_cast<std::uint32_t>(ip);
            if (ref != 0xFFFFFFFFu && ip > ref && (ip - ref) <= detail::kLz4MaxDistance &&
                detail::readU32LE(src + ref) == detail::readU32LE(src + ip)) {
                matchPos = ref;
                found = true;
                break;
            }
            step = searchMatchNb >> 6;
            ++searchMatchNb;
            ip += step;
        }
        if (!found) {
            break;
        }

        // Extend match backwards while within anchor and distance limit.
        while (ip > anchor && matchPos > 0 && src[ip - 1] == src[matchPos - 1]) {
            --ip;
            --matchPos;
        }

        // Emit literals [anchor..ip).
        const std::size_t litLen = ip - anchor;
        const std::size_t tokenIdx = out.size();
        out.push_back(static_cast<std::uint8_t>(std::min<std::size_t>(litLen, 15) << 4));
        if (litLen >= 15) {
            detail::emitLen(out, litLen - 15);
        }
        if (litLen > 0) {
            out.insert(out.end(), src + anchor, src + ip);
        }

        // Emit match offset (little-endian uint16).
        const std::uint16_t offset = static_cast<std::uint16_t>(ip - matchPos);
        out.push_back(static_cast<std::uint8_t>(offset & 0xFFu));
        out.push_back(static_cast<std::uint8_t>((offset >> 8) & 0xFFu));

        // Extend match forwards up to matchlimit.
        std::size_t matchLen = detail::kLz4MinMatch;
        while (ip + matchLen < matchlimit && src[matchPos + matchLen] == src[ip + matchLen]) {
            ++matchLen;
        }

        const std::size_t encodedMatch = matchLen - detail::kLz4MinMatch;
        out[tokenIdx] |= static_cast<std::uint8_t>(std::min<std::size_t>(encodedMatch, 15));
        if (encodedMatch >= 15) {
            detail::emitLen(out, encodedMatch - 15);
        }

        ip += matchLen;
        anchor = ip;
        if (ip <= mflimit) {
            table[detail::lz4Hash4(src + ip - 2)] = static_cast<std::uint32_t>(ip - 2);
        }
    }

    // Emit final literals [anchor..srcSize).
    const std::size_t lastLit = srcSize - anchor;
    out.push_back(static_cast<std::uint8_t>(std::min<std::size_t>(lastLit, 15) << 4));
    if (lastLit >= 15) {
        detail::emitLen(out, lastLit - 15);
    }
    if (lastLit > 0) {
        out.insert(out.end(), src + anchor, src + srcSize);
    }
    return out;
}

// Decompresses a standard LZ4 block into exactly expectedSize bytes; returns std::nullopt on any corruption.
inline std::optional<std::vector<std::uint8_t>> lz4DecompressBlock(const std::uint8_t* src, std::size_t srcSize,
                                                                   std::size_t expectedSize) {
    if (expectedSize == 0) {
        return srcSize == 0 ? std::optional<std::vector<std::uint8_t>>(std::vector<std::uint8_t>{}) : std::nullopt;
    }
    if (src == nullptr || srcSize == 0) {
        return std::nullopt;
    }
    std::vector<std::uint8_t> out(expectedSize);
    std::size_t ip = 0;
    std::size_t op = 0;

    while (ip < srcSize) {
        const std::uint8_t token = src[ip++];
        std::size_t litLen = token >> 4;
        if (litLen == 15) {
            while (true) {
                if (ip >= srcSize) {
                    return std::nullopt;
                }
                const std::uint8_t extra = src[ip++];
                if (extra > expectedSize - litLen) {
                    return std::nullopt;
                }
                litLen += extra;
                if (extra != 255) {
                    break;
                }
            }
        }
        if (litLen > srcSize - ip || litLen > expectedSize - op) {
            return std::nullopt;
        }
        if (litLen > 0) {
            std::memcpy(out.data() + op, src + ip, litLen);
            ip += litLen;
            op += litLen;
        }
        if (ip == srcSize) {
            break; // End of block after final literals.
        }
        if (srcSize - ip < 2) {
            return std::nullopt;
        }
        const std::size_t offset = static_cast<std::size_t>(src[ip]) | (static_cast<std::size_t>(src[ip + 1]) << 8);
        ip += 2;
        if (offset == 0 || offset > op) {
            return std::nullopt;
        }
        std::size_t matchLen = (token & 0x0Fu) + detail::kLz4MinMatch;
        if ((token & 0x0Fu) == 15) {
            while (true) {
                if (ip >= srcSize) {
                    return std::nullopt;
                }
                const std::uint8_t extra = src[ip++];
                if (extra > expectedSize - matchLen) {
                    return std::nullopt;
                }
                matchLen += extra;
                if (extra != 255) {
                    break;
                }
            }
        }
        if (matchLen > expectedSize - op) {
            return std::nullopt;
        }
        // Copy byte-by-byte to support overlapping RLE matches (offset < matchLen) safely.
        const std::size_t matchStart = op - offset;
        for (std::size_t i = 0; i < matchLen; ++i) {
            out[op + i] = out[matchStart + i];
        }
        op += matchLen;
    }
    if (op != expectedSize) {
        return std::nullopt;
    }
    return out;
}

// Wraps payload with 4-byte LE uncompressed size + LZ4 block. Returns std::nullopt if compression doesn't save space.
inline std::optional<std::vector<std::uint8_t>> lz4CompressPayload(const std::uint8_t* src, std::size_t srcSize) {
    if (src == nullptr || srcSize == 0 || srcSize > 0xFFFFFFFFu) {
        return std::nullopt;
    }
    const std::vector<std::uint8_t> block = lz4CompressBlock(src, srcSize);
    if (block.size() + 4 >= srcSize) {
        return std::nullopt;
    }
    std::vector<std::uint8_t> out(4 + block.size());
    detail::writeU32LE(out.data(), static_cast<std::uint32_t>(srcSize));
    std::memcpy(out.data() + 4, block.data(), block.size());
    return out;
}

// Unwraps [uint32_t origSize][LZ4 block] with strict upper bound maxOutputSize.
inline std::optional<std::vector<std::uint8_t>> lz4DecompressPayload(const std::uint8_t* src, std::size_t srcSize,
                                                                     std::size_t maxOutputSize) {
    if (src == nullptr || srcSize < 4) {
        return std::nullopt;
    }
    const std::uint32_t origSize = detail::readU32LE(src);
    if (origSize > maxOutputSize) {
        return std::nullopt;
    }
    return lz4DecompressBlock(src + 4, srcSize - 4, origSize);
}

} // namespace pz2
