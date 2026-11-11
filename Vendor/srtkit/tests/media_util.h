// Tiện ích test: đọc file Annex-B (có AUD) và ADTS để giả lập output của encoder.
#pragma once
#include <cstdio>
#include <fstream>
#include <iterator>
#include <string>
#include <vector>

#include "srtkit/TsMuxer.h"

struct VideoAU { std::vector<uint8_t> data; bool key; };
struct AudioAU { std::vector<uint8_t> raw; };

inline std::vector<uint8_t> readFile(const std::string& p) {
    std::ifstream f(p, std::ios::binary);
    return std::vector<uint8_t>((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
}

// Tách theo AUD; bỏ SPS/PPS/VPS ra paramSets (giống VideoToolbox: tham số nằm ngoài sample)
inline std::vector<VideoAU> loadVideo(const std::string& path, bool hevc,
                                      std::vector<std::vector<uint8_t>>& params) {
    auto buf = readFile(path);
    auto nals = srtkit::annexb::split(buf.data(), buf.size());
    std::vector<VideoAU> out;
    VideoAU cur{{}, false};
    static const uint8_t sc[4] = {0, 0, 0, 1};
    for (auto& n : nals) {
        int t = hevc ? srtkit::annexb::hevcType(n) : srtkit::annexb::h264Type(n);
        bool aud = hevc ? t == 35 : t == 9;
        bool param = hevc ? (t == 32 || t == 33 || t == 34) : (t == 7 || t == 8);
        if (aud) { if (!cur.data.empty()) out.push_back(cur); cur = {{}, false}; continue; }
        if (param) {
            if (params.size() < (hevc ? 3u : 2u)) params.emplace_back(n.data, n.data + n.size);
            continue;
        }
        if (hevc ? (t == 39 || t == 40) : t == 6) continue;  // bỏ SEI gốc
        if (hevc ? (t >= 16 && t <= 21) : t == 5) cur.key = true;
        cur.data.insert(cur.data.end(), sc, sc + 4);
        cur.data.insert(cur.data.end(), n.data, n.data + n.size);
    }
    if (!cur.data.empty()) out.push_back(cur);
    return out;
}

inline std::vector<AudioAU> loadAdts(const std::string& path) {
    auto b = readFile(path);
    std::vector<AudioAU> out;
    size_t i = 0;
    while (i + 7 <= b.size()) {
        if (!(b[i] == 0xFF && (b[i + 1] & 0xF0) == 0xF0)) { ++i; continue; }
        size_t fl = ((b[i + 3] & 3) << 11) | (b[i + 4] << 3) | (b[i + 5] >> 5);
        size_t hl = (b[i + 1] & 1) ? 7 : 9;
        if (i + fl > b.size() || fl < hl) break;
        out.push_back({std::vector<uint8_t>(b.begin() + i + hl, b.begin() + i + fl)});
        i += fl;
    }
    return out;
}
