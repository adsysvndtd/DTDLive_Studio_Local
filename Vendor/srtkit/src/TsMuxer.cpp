#include "srtkit/TsMuxer.h"

#include <cstring>

namespace srtkit {

// ---------------------------------------------------------------------------
// CRC32/MPEG-2
// ---------------------------------------------------------------------------
uint32_t crc32Mpeg(const uint8_t* data, size_t len) {
    static uint32_t table[256];
    static bool init = false;
    if (!init) {
        for (uint32_t i = 0; i < 256; ++i) {
            uint32_t c = i << 24;
            for (int k = 0; k < 8; ++k) c = (c & 0x80000000u) ? (c << 1) ^ 0x04C11DB7u : (c << 1);
            table[i] = c;
        }
        init = true;
    }
    uint32_t crc = 0xFFFFFFFFu;
    for (size_t i = 0; i < len; ++i) crc = (crc << 8) ^ table[((crc >> 24) ^ data[i]) & 0xFF];
    return crc;
}

// ---------------------------------------------------------------------------
// Annex-B helpers
// ---------------------------------------------------------------------------
namespace annexb {

std::vector<Nal> split(const uint8_t* buf, size_t len) {
    std::vector<Nal> out;
    size_t i = 0, start = SIZE_MAX;
    while (i + 3 <= len) {
        if (buf[i] == 0 && buf[i + 1] == 0 && (buf[i + 2] == 1 || (i + 3 < len && buf[i + 2] == 0 && buf[i + 3] == 1))) {
            size_t scLen = (buf[i + 2] == 1) ? 3 : 4;
            if (start != SIZE_MAX) {
                size_t end = i;
                while (end > start && buf[end - 1] == 0) --end;  // bỏ trailing zero
                if (end > start) out.push_back({buf + start, end - start});
            }
            i += scLen;
            start = i;
        } else {
            ++i;
        }
    }
    if (start != SIZE_MAX && start < len) out.push_back({buf + start, len - start});
    return out;
}

int h264Type(const Nal& n) { return n.size ? (n.data[0] & 0x1F) : -1; }
int hevcType(const Nal& n) { return n.size ? ((n.data[0] >> 1) & 0x3F) : -1; }

std::vector<uint8_t> fromLengthPrefixed(const uint8_t* buf, size_t len, int lengthSize) {
    std::vector<uint8_t> out;
    out.reserve(len + 16);
    size_t i = 0;
    while (i + lengthSize <= len) {
        uint32_t n = 0;
        for (int k = 0; k < lengthSize; ++k) n = (n << 8) | buf[i + k];
        i += lengthSize;
        if (n == 0 || i + n > len) break;
        static const uint8_t sc[4] = {0, 0, 0, 1};
        out.insert(out.end(), sc, sc + 4);
        out.insert(out.end(), buf + i, buf + i + n);
        i += n;
    }
    return out;
}

} // namespace annexb

// ---------------------------------------------------------------------------
namespace {

constexpr int64_t kPtsOffset90 = 63000;     // PTS/DTS đi trước PCR 700 ms (giống max_delay của ffmpeg)
constexpr int64_t kTsMask = (1LL << 33) - 1;

inline int64_t us90(int64_t us) { return (us * 9) / 100; }

void putTs(uint8_t* p, int prefix, int64_t ts) {
    ts &= kTsMask;
    p[0] = static_cast<uint8_t>((prefix << 4) | (((ts >> 30) & 0x07) << 1) | 1);
    p[1] = static_cast<uint8_t>((ts >> 22) & 0xFF);
    p[2] = static_cast<uint8_t>((((ts >> 15) & 0x7F) << 1) | 1);
    p[3] = static_cast<uint8_t>((ts >> 7) & 0xFF);
    p[4] = static_cast<uint8_t>(((ts & 0x7F) << 1) | 1);
}

void putPcr(uint8_t* p, int64_t base) {
    base &= kTsMask;
    p[0] = static_cast<uint8_t>(base >> 25);
    p[1] = static_cast<uint8_t>(base >> 17);
    p[2] = static_cast<uint8_t>(base >> 9);
    p[3] = static_cast<uint8_t>(base >> 1);
    p[4] = static_cast<uint8_t>(((base & 1) << 7) | 0x7E);
    p[5] = 0;
}

int aacSampleRateIndex(int sr) {
    static const int rates[] = {96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350};
    for (int i = 0; i < 13; ++i) if (rates[i] == sr) return i;
    return 3;
}

} // namespace

// ---------------------------------------------------------------------------
TsMuxer::TsMuxer(const Config& cfg, PacketSink sink) : cfg_(cfg), sink_(std::move(sink)) {}

void TsMuxer::reset() {
    std::memset(cc_, 0, sizeof(cc_));
    psiSent_ = false;
    lastPsiUs_ = 0;
}

void TsMuxer::setVideoParameterSets(const std::vector<std::vector<uint8_t>>& nals) { paramSets_ = nals; }

std::vector<uint8_t> TsMuxer::buildPat() const {
    std::vector<uint8_t> s = {0x00, 0xB0, 0x00, 0x00, 0x01, 0xC1, 0x00, 0x00,
                              0x00, 0x01, static_cast<uint8_t>(0xE0 | (kPmtPid >> 8)), static_cast<uint8_t>(kPmtPid & 0xFF)};
    size_t secLen = s.size() - 3 + 4;
    s[1] = static_cast<uint8_t>(0xB0 | ((secLen >> 8) & 0x0F));
    s[2] = static_cast<uint8_t>(secLen & 0xFF);
    uint32_t crc = crc32Mpeg(s.data(), s.size());
    for (int i = 3; i >= 0; --i) s.push_back(static_cast<uint8_t>(crc >> (i * 8)));
    return s;
}

std::vector<uint8_t> TsMuxer::buildPmt() const {
    uint16_t pcrPid = cfg_.hasVideo ? kVideoPid : kAudioPid;
    std::vector<uint8_t> s = {0x02, 0xB0, 0x00, 0x00, 0x01, 0xC1, 0x00, 0x00,
                              static_cast<uint8_t>(0xE0 | (pcrPid >> 8)), static_cast<uint8_t>(pcrPid & 0xFF),
                              0xF0, 0x00};
    auto addStream = [&](uint8_t type, uint16_t pid, const std::vector<uint8_t>& desc) {
        s.push_back(type);
        s.push_back(static_cast<uint8_t>(0xE0 | (pid >> 8)));
        s.push_back(static_cast<uint8_t>(pid & 0xFF));
        s.push_back(static_cast<uint8_t>(0xF0 | ((desc.size() >> 8) & 0x0F)));
        s.push_back(static_cast<uint8_t>(desc.size() & 0xFF));
        s.insert(s.end(), desc.begin(), desc.end());
    };
    if (cfg_.hasVideo) addStream(cfg_.videoCodec == VideoCodec::HEVC ? 0x24 : 0x1B, kVideoPid, {});
    if (cfg_.hasAudio) {
        if (cfg_.audioCodec == AudioCodec::AAC) {
            addStream(0x0F, kAudioPid, {});
        } else {
            // Opus trong TS (ETSI TS 102 366 Annex): registration 'Opus' + extension descriptor
            std::vector<uint8_t> d = {0x05, 0x04, 'O', 'p', 'u', 's',
                                      0x7F, 0x02, 0x80, static_cast<uint8_t>(cfg_.audioChannels)};
            addStream(0x06, kAudioPid, d);
        }
    }
    size_t secLen = s.size() - 3 + 4;
    s[1] = static_cast<uint8_t>(0xB0 | ((secLen >> 8) & 0x0F));
    s[2] = static_cast<uint8_t>(secLen & 0xFF);
    uint32_t crc = crc32Mpeg(s.data(), s.size());
    for (int i = 3; i >= 0; --i) s.push_back(static_cast<uint8_t>(crc >> (i * 8)));
    return s;
}

void TsMuxer::writeSection(uint16_t pid, const std::vector<uint8_t>& section) {
    uint8_t pkt[188];
    std::memset(pkt, 0xFF, sizeof(pkt));
    pkt[0] = 0x47;
    pkt[1] = static_cast<uint8_t>(0x40 | (pid >> 8));
    pkt[2] = static_cast<uint8_t>(pid & 0xFF);
    pkt[3] = static_cast<uint8_t>(0x10 | (cc_[pid] & 0x0F));
    cc_[pid] = (cc_[pid] + 1) & 0x0F;
    pkt[4] = 0x00;  // pointer_field
    std::memcpy(pkt + 5, section.data(), section.size() < 183 ? section.size() : 183);
    sink_(pkt);
}

void TsMuxer::writePsi(int64_t nowUs) {
    writeSection(0x0000, buildPat());
    writeSection(kPmtPid, buildPmt());
    psiSent_ = true;
    lastPsiUs_ = nowUs;
}

void TsMuxer::writePes(uint16_t pid, uint8_t streamId, const uint8_t* data, size_t len,
                       int64_t pts90, int64_t dts90, bool withPcr, int64_t pcr90, bool randomAccess,
                       bool boundedLength) {
    // PES header
    uint8_t hdr[19];
    size_t h = 0;
    bool hasDts = dts90 != pts90;
    hdr[h++] = 0x00; hdr[h++] = 0x00; hdr[h++] = 0x01; hdr[h++] = streamId;
    size_t pesHdrDataLen = hasDts ? 10 : 5;
    size_t pesLen = 3 + pesHdrDataLen + len;
    if (!boundedLength || pesLen > 0xFFFF) pesLen = 0;
    hdr[h++] = static_cast<uint8_t>(pesLen >> 8);
    hdr[h++] = static_cast<uint8_t>(pesLen & 0xFF);
    hdr[h++] = 0x80;                           // marker '10', không scramble
    hdr[h++] = hasDts ? 0xC0 : 0x80;           // PTS_DTS_flags
    hdr[h++] = static_cast<uint8_t>(pesHdrDataLen);
    putTs(hdr + h, hasDts ? 0x3 : 0x2, pts90); h += 5;
    if (hasDts) { putTs(hdr + h, 0x1, dts90); h += 5; }

    size_t total = h + len;
    size_t pos = 0;  // vị trí trong (hdr + data)
    bool first = true;
    uint8_t pkt[188];

    auto copyPayload = [&](uint8_t* dst, size_t n) {
        size_t done = 0;
        while (done < n) {
            if (pos < h) {
                size_t c = (h - pos) < (n - done) ? (h - pos) : (n - done);
                std::memcpy(dst + done, hdr + pos, c);
                pos += c; done += c;
            } else {
                size_t off = pos - h;
                size_t c = n - done;
                std::memcpy(dst + done, data + off, c);
                pos += c; done += c;
            }
        }
    };

    while (pos < total) {
        size_t remaining = total - pos;
        // Adaptation field cơ bản
        uint8_t af[184];
        size_t afLen = 0;  // tính cả byte adaptation_field_length
        if (first && (withPcr || randomAccess)) {
            af[1] = static_cast<uint8_t>((randomAccess ? 0x40 : 0x00) | (withPcr ? 0x10 : 0x00));
            afLen = 2;
            if (withPcr) { putPcr(af + 2, pcr90); afLen += 6; }
        }
        size_t space = 184 - afLen;
        if (remaining < space) {
            // cần stuffing
            size_t stuff = space - remaining;
            if (afLen == 0) {
                if (stuff == 1) { afLen = 1; }
                else { af[1] = 0x00; afLen = 2; stuff -= 2; std::memset(af + 2, 0xFF, stuff); afLen += stuff; }
            } else {
                std::memset(af + afLen, 0xFF, stuff);
                afLen += stuff;
            }
            space = 184 - afLen;
        }
        if (afLen > 0) af[0] = static_cast<uint8_t>(afLen - 1);

        pkt[0] = 0x47;
        pkt[1] = static_cast<uint8_t>((first ? 0x40 : 0x00) | (pid >> 8));
        pkt[2] = static_cast<uint8_t>(pid & 0xFF);
        pkt[3] = static_cast<uint8_t>((afLen ? 0x30 : 0x10) | (cc_[pid] & 0x0F));
        cc_[pid] = (cc_[pid] + 1) & 0x0F;
        if (afLen) std::memcpy(pkt + 4, af, afLen);
        copyPayload(pkt + 4 + afLen, space);
        sink_(pkt);
        first = false;
    }
}

void TsMuxer::writeVideo(const uint8_t* buf, size_t len, int64_t ptsUs, int64_t dtsUs, bool keyframe,
                         const std::vector<uint8_t>* seiNal) {
    if (!cfg_.hasVideo || len == 0) return;
    const bool hevc = cfg_.videoCodec == VideoCodec::HEVC;

    if (!psiSent_ || keyframe || (dtsUs - lastPsiUs_) > cfg_.psiIntervalMs * 1000LL) writePsi(dtsUs);

    auto nals = annexb::split(buf, len);
    bool hasParams = false;
    for (auto& n : nals) {
        int t = hevc ? annexb::hevcType(n) : annexb::h264Type(n);
        if ((!hevc && t == 7) || (hevc && t == 33)) hasParams = true;
    }

    static const uint8_t sc[4] = {0, 0, 0, 1};
    scratch_.clear();
    scratch_.reserve(len + 256);
    // AUD
    if (hevc) { const uint8_t aud[] = {0, 0, 0, 1, 0x46, 0x01, 0x50}; scratch_.insert(scratch_.end(), aud, aud + 7); }
    else      { const uint8_t aud[] = {0, 0, 0, 1, 0x09, 0xF0};       scratch_.insert(scratch_.end(), aud, aud + 6); }
    // Tham số trước keyframe
    if (keyframe && !hasParams) {
        for (auto& p : paramSets_) { scratch_.insert(scratch_.end(), sc, sc + 4); scratch_.insert(scratch_.end(), p.begin(), p.end()); }
    }
    bool seiDone = (seiNal == nullptr || seiNal->empty());
    for (auto& n : nals) {
        int t = hevc ? annexb::hevcType(n) : annexb::h264Type(n);
        if ((!hevc && t == 9) || (hevc && t == 35)) continue;  // bỏ AUD gốc
        bool isVcl = hevc ? (t >= 0 && t <= 31) : (t >= 1 && t <= 5);
        if (!seiDone && isVcl) {
            scratch_.insert(scratch_.end(), sc, sc + 4);
            scratch_.insert(scratch_.end(), seiNal->begin(), seiNal->end());
            seiDone = true;
        }
        scratch_.insert(scratch_.end(), sc, sc + 4);
        scratch_.insert(scratch_.end(), n.data, n.data + n.size);
    }

    int64_t dts90 = us90(dtsUs);
    int64_t pts90 = us90(ptsUs);
    writePes(kVideoPid, 0xE0, scratch_.data(), scratch_.size(),
             pts90 + kPtsOffset90, dts90 + kPtsOffset90, /*withPcr*/ true, dts90, keyframe, /*bounded*/ false);
}

void TsMuxer::writeAudio(const uint8_t* data, size_t len, int64_t ptsUs) {
    if (!cfg_.hasAudio || len == 0) return;
    if (!psiSent_ || (!cfg_.hasVideo && (ptsUs - lastPsiUs_) > cfg_.psiIntervalMs * 1000LL)) writePsi(ptsUs);

    scratch_.clear();
    uint8_t streamId;
    if (cfg_.audioCodec == AudioCodec::AAC) {
        streamId = 0xC0;
        bool hasAdts = len >= 7 && data[0] == 0xFF && (data[1] & 0xF0) == 0xF0;
        if (!hasAdts) {
            size_t frameLen = len + 7;
            int sf = aacSampleRateIndex(cfg_.audioSampleRate);
            int ch = cfg_.audioChannels;
            int prof = cfg_.aacProfile - 1;
            uint8_t a[7] = {0xFF, 0xF1,
                            static_cast<uint8_t>((prof << 6) | (sf << 2) | ((ch >> 2) & 1)),
                            static_cast<uint8_t>(((ch & 3) << 6) | ((frameLen >> 11) & 3)),
                            static_cast<uint8_t>((frameLen >> 3) & 0xFF),
                            static_cast<uint8_t>(((frameLen & 7) << 5) | 0x1F),
                            0xFC};
            scratch_.insert(scratch_.end(), a, a + 7);
        }
        scratch_.insert(scratch_.end(), data, data + len);
    } else {
        streamId = 0xBD;  // private_stream_1
        scratch_.push_back(0x7F);
        scratch_.push_back(0xE0);  // control header, không trim
        size_t n = len;
        while (n >= 255) { scratch_.push_back(0xFF); n -= 255; }
        scratch_.push_back(static_cast<uint8_t>(n));
        scratch_.insert(scratch_.end(), data, data + len);
    }
    int64_t pts90 = us90(ptsUs);
    bool pcrHere = !cfg_.hasVideo;
    writePes(kAudioPid, streamId, scratch_.data(), scratch_.size(),
             pts90 + kPtsOffset90, pts90 + kPtsOffset90, pcrHere, pts90, pcrHere, /*bounded*/ true);
}

} // namespace srtkit
