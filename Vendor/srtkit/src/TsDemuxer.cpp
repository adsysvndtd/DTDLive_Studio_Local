#include "srtkit/TsDemuxer.h"

#include <cstring>

namespace srtkit {

namespace {
int64_t readTs(const uint8_t* p) {
    return (static_cast<int64_t>((p[0] >> 1) & 0x07) << 30) | (static_cast<int64_t>(p[1]) << 22) |
           (static_cast<int64_t>((p[2] >> 1) & 0x7F) << 15) | (static_cast<int64_t>(p[3]) << 7) |
           ((p[4] >> 1) & 0x7F);
}
const int kAacRates[] = {96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350};
} // namespace

void TsDemuxer::reset() {
    videoPid_ = -1;
    videoType_ = 0;
    pmtPid_ = -1;
    audioPid_ = -1;
    pes_.clear();
    carry_.clear();
}

void TsDemuxer::feed(const uint8_t* data, size_t len) {
    // Gộp phần dư từ lần trước, đồng bộ lại theo sync byte 0x47
    std::vector<uint8_t> tmp;
    if (!carry_.empty()) {
        tmp = carry_;
        tmp.insert(tmp.end(), data, data + len);
        data = tmp.data();
        len = tmp.size();
    }
    size_t i = 0;
    while (i + 188 <= len) {
        if (data[i] != 0x47) { ++i; continue; }
        handlePacket(data + i);
        i += 188;
    }
    carry_.assign(data + i, data + len);
}

void TsDemuxer::handlePacket(const uint8_t* p) {
    bool pusi = p[1] & 0x40;
    uint16_t pid = static_cast<uint16_t>(((p[1] & 0x1F) << 8) | p[2]);
    int afc = (p[3] >> 4) & 0x03;
    size_t off = 4;
    if (afc == 0 || afc == 2) return;           // chỉ adaptation field
    if (afc == 3) off += 1 + p[4];
    if (off >= 188) return;
    const uint8_t* pl = p + off;
    size_t plLen = 188 - off;

    if (pid == 0) {
        if (!pusi) return;
        size_t ptr = pl[0];
        if (1 + ptr >= plLen) return;
        parsePat(pl + 1 + ptr, plLen - 1 - ptr);
        return;
    }
    if (pid == pmtPid_) {
        if (!pusi) return;
        size_t ptr = pl[0];
        if (1 + ptr >= plLen) return;
        parsePmt(pl + 1 + ptr, plLen - 1 - ptr);
        return;
    }
    if (pid != audioPid_ && pid != videoPid_) return;

    Pes& pe = pes_[pid];
    if (pusi) {
        flushPes(pid);
        pe.buf.clear();
        pe.active = true;
    }
    // A video PES can be unbounded; discard an incomplete oversized access unit.
    if (pe.buf.size() + plLen > 8 * 1024 * 1024) {
        pe.buf.clear();
        pe.active = false;
    }
    if (pe.active) pe.buf.insert(pe.buf.end(), pl, pl + plLen);
    // PES có độ dài xác định -> flush ngay khi đủ
    if (pe.buf.size() >= 6) {
        size_t pesLen = (static_cast<size_t>(pe.buf[4]) << 8) | pe.buf[5];
        if (pesLen && pe.buf.size() >= pesLen + 6) flushPes(pid);
    }
}

void TsDemuxer::parsePat(const uint8_t* s, size_t len) {
    if (len < 12 || s[0] != 0x00) return;
    size_t secLen = ((s[1] & 0x0F) << 8) | s[2];
    if (secLen + 3 > len || secLen < 9) return;
    size_t end = 3 + secLen - 4;
    for (size_t i = 8; i + 4 <= end; i += 4) {
        uint16_t prog = static_cast<uint16_t>((s[i] << 8) | s[i + 1]);
        uint16_t pid = static_cast<uint16_t>(((s[i + 2] & 0x1F) << 8) | s[i + 3]);
        if (prog != 0) { pmtPid_ = pid; return; }
    }
}

void TsDemuxer::parsePmt(const uint8_t* s, size_t len) {
    if (len < 16 || s[0] != 0x02) return;
    size_t secLen = ((s[1] & 0x0F) << 8) | s[2];
    if (secLen < 13 || secLen + 3 > len) return;
    size_t end = 3 + secLen - 4;
    size_t progInfo = ((s[10] & 0x0F) << 8) | s[11];
    size_t i = 12 + progInfo;
    while (i + 5 <= end) {
        uint8_t type = s[i];
        uint16_t pid = static_cast<uint16_t>(((s[i + 1] & 0x1F) << 8) | s[i + 2]);
        size_t esInfo = ((s[i + 3] & 0x0F) << 8) | s[i + 4];
        const uint8_t* desc = s + i + 5;
        if (i + 5 + esInfo > end) return;
        if (videoSink_ && videoPid_ < 0 && (type == 0x1b || (acceptHevc_ && type == 0x24))) { videoPid_ = pid; videoType_ = type; }
        if (sink_ && audioPid_ < 0) {
            if (type == 0x0F) { audioPid_ = pid; audioCodec_ = AudioCodec::AAC; }
            else if (type == 0x06) {
                // tìm registration 'Opus'
                for (size_t d = 0; d + 2 <= esInfo;) {
                    uint8_t tag = desc[d], dl = desc[d + 1];
                    if (d + 2 + dl > esInfo) break;
                    if (tag == 0x05 && dl >= 4 && std::memcmp(desc + d + 2, "Opus", 4) == 0) {
                        audioPid_ = pid; audioCodec_ = AudioCodec::Opus;
                    }
                    if (tag == 0x7F && dl >= 2 && desc[d + 2] == 0x80) opusChannels_ = desc[d + 3] ? desc[d + 3] : 2;
                    d += 2 + dl;
                }
            }
        }
        i += 5 + esInfo;
    }
}

void TsDemuxer::flushPes(uint16_t pid) {
    Pes& pe = pes_[pid];
    if (!pe.active || pe.buf.size() < 9) { pe.active = false; return; }
    const uint8_t* b = pe.buf.data();
    if (!(b[0] == 0 && b[1] == 0 && b[2] == 1)) { pe.active = false; pe.buf.clear(); return; }
    size_t hdrLen = b[8];
    int64_t ptsUs = 0;
    if ((b[7] & 0x80) && pe.buf.size() >= 14) ptsUs = readTs(b + 9) * 100 / 9;
    size_t esOff = 9 + hdrLen;
    size_t pesLen = (static_cast<size_t>(b[4]) << 8) | b[5];
    size_t esEnd = pesLen ? std::min(pe.buf.size(), pesLen + 6) : pe.buf.size();
    if (esOff < esEnd) {
        if (pid == videoPid_) videoSink_(b + esOff, esEnd - esOff, ptsUs);
        else if (audioCodec_ == AudioCodec::AAC) emitAac(b + esOff, esEnd - esOff, ptsUs);
        else emitOpus(b + esOff, esEnd - esOff, ptsUs);
    }
    pe.active = false;
    pe.buf.clear();
}

void TsDemuxer::emitAac(const uint8_t* es, size_t len, int64_t ptsUs) {
    size_t i = 0;
    int frameIdx = 0;
    while (i + 7 <= len) {
        if (!(es[i] == 0xFF && (es[i + 1] & 0xF0) == 0xF0)) { ++i; continue; }
        bool protAbsent = es[i + 1] & 0x01;
        int prof = (es[i + 2] >> 6) & 0x03;
        int sf = (es[i + 2] >> 2) & 0x0F;
        int ch = ((es[i + 2] & 0x01) << 2) | ((es[i + 3] >> 6) & 0x03);
        size_t fl = ((es[i + 3] & 0x03) << 11) | (es[i + 4] << 3) | ((es[i + 5] >> 5) & 0x07);
        size_t hl = protAbsent ? 7 : 9;
        if (fl < hl || i + fl > len) break;
        DemuxedAudioFrame f;
        f.codec = AudioCodec::AAC;
        f.sampleRate = sf < 13 ? kAacRates[sf] : 48000;
        f.channels = ch;
        f.ptsUs = ptsUs + static_cast<int64_t>(frameIdx) * 1024 * 1000000LL / f.sampleRate;
        f.data.assign(es + i + hl, es + i + fl);
        int aot = prof + 1;
        f.asc = {static_cast<uint8_t>((aot << 3) | (sf >> 1)), static_cast<uint8_t>(((sf & 1) << 7) | (ch << 3))};
        if (sink_) sink_(f);
        i += fl;
        ++frameIdx;
    }
}

void TsDemuxer::emitOpus(const uint8_t* es, size_t len, int64_t ptsUs) {
    size_t i = 0;
    while (i + 2 <= len) {
        // control header 0x7FE0 (11 bit 0x3FF + flags)
        if (!(es[i] == 0x7F && (es[i + 1] & 0xE0) == 0xE0)) break;
        bool startTrim = es[i + 1] & 0x10, endTrim = es[i + 1] & 0x08, ctrlExt = es[i + 1] & 0x04;
        i += 2;
        size_t size = 0;
        while (i < len) { uint8_t v = es[i++]; size += v; if (v != 0xFF) break; }
        if (startTrim) i += 2;
        if (endTrim) i += 2;
        if (ctrlExt) { if (i >= len) break; i += 1 + es[i]; }
        if (i + size > len) break;
        DemuxedAudioFrame f;
        f.codec = AudioCodec::Opus;
        f.sampleRate = 48000;
        f.channels = opusChannels_;
        f.ptsUs = ptsUs;
        f.data.assign(es + i, es + i + size);
        if (sink_) sink_(f);
        i += size;
    }
}

} // namespace srtkit
