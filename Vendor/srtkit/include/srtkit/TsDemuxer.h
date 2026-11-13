// MPEG-TS demuxer tối giản (dùng cho Talkback): lấy audio AAC / Opus từ luồng TS.
#pragma once

#include <cstdint>
#include <functional>
#include <map>
#include <vector>

#include "srtkit/Types.h"

namespace srtkit {

struct DemuxedAudioFrame {
    AudioCodec codec;
    int sampleRate = 0;      // AAC: từ ADTS; Opus: luôn 48000
    int channels = 0;
    int64_t ptsUs = 0;
    std::vector<uint8_t> data;     // AAC: raw (đã bỏ ADTS); Opus: gói Opus
    std::vector<uint8_t> asc;      // AAC AudioSpecificConfig (2 byte) để khởi tạo decoder
};

class TsDemuxer {
public:
    using AudioSink = std::function<void(const DemuxedAudioFrame&)>;
    using VideoSink = std::function<void(const uint8_t*, size_t, int64_t)>;
    explicit TsDemuxer(AudioSink sink, VideoSink video = {})
        : sink_(std::move(sink)), videoSink_(std::move(video)) {}

    // Đưa vào dữ liệu bất kỳ độ dài (bội số 188 trong thực tế SRT/UDP).
    void feed(const uint8_t* data, size_t len);
    void reset();
    /// Video stream type from the PMT: 0x1b = H.264, 0x24 = HEVC (DTD Studio ingest).
    bool videoIsHevc() const { return videoType_ == 0x24; }
    /// Accept HEVC video PIDs as well as H.264 (off by default: the camera receiver decodes H.264 only).
    void setAcceptHevc(bool on) { acceptHevc_ = on; }
    /// TS continuity-counter gaps seen (lost packets) and video access units dropped because of them.
    /// A dropped AU is signalled to the video sink as a call with count == 0 (decoder: wait for the next IDR).
    uint64_t ccErrors() const { return ccErrors_; }
    uint64_t videoDropped() const { return videoDropped_; }

private:
    struct Pes { std::vector<uint8_t> buf; bool active = false; bool corrupt = false; int lastCc = -1; };
    void handlePacket(const uint8_t* p);
    void parsePat(const uint8_t* sec, size_t len);
    void parsePmt(const uint8_t* sec, size_t len);
    void flushPes(uint16_t pid);
    void emitAac(const uint8_t* es, size_t len, int64_t ptsUs);
    void emitOpus(const uint8_t* es, size_t len, int64_t ptsUs);

    AudioSink sink_;
    VideoSink videoSink_;
    int videoPid_ = -1;
    int videoType_ = 0;
    bool acceptHevc_ = false;
    int pmtPid_ = -1;
    int audioPid_ = -1;
    AudioCodec audioCodec_ = AudioCodec::AAC;
    int opusChannels_ = 2;
    std::map<uint16_t, Pes> pes_;
    std::vector<uint8_t> carry_;
    uint64_t ccErrors_ = 0, videoDropped_ = 0;
};

} // namespace srtkit
