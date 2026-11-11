// MPEG-TS muxer tối giản cho live: H.264 / HEVC + AAC / Opus.
// Đầu vào: video Annex-B, audio raw (AAC raw access unit hoặc gói Opus).
// Đầu ra: các gói TS 188 byte qua callback.
#pragma once

#include <cstdint>
#include <functional>
#include <vector>

#include "srtkit/Types.h"

namespace srtkit {

class TsMuxer {
public:
    using PacketSink = std::function<void(const uint8_t* ts188)>;

    struct Config {
        bool hasVideo = true;
        bool hasAudio = true;
        VideoCodec videoCodec = VideoCodec::H264;
        AudioCodec audioCodec = AudioCodec::AAC;
        int audioSampleRate = 48000;
        int audioChannels = 2;
        int aacProfile = 2;
        int psiIntervalMs = 250;   // chèn lại PAT/PMT tối đa mỗi N ms (luôn chèn trước keyframe)
    };

    static constexpr uint16_t kPmtPid = 0x1000;
    static constexpr uint16_t kVideoPid = 0x100;
    static constexpr uint16_t kAudioPid = 0x101;

    TsMuxer(const Config& cfg, PacketSink sink);

    // Bắt đầu lại (sau reconnect): reset continuity counter, buộc gửi PAT/PMT.
    void reset();

    // annexB phải là một access unit hoàn chỉnh. Nếu là keyframe mà thiếu SPS/PPS(/VPS)
    // thì muxer tự chèn bộ tham số đã lưu bằng setVideoParameterSets().
    // seiNal: NAL SEI hoàn chỉnh (có header, đã chống giả start code), chèn trước slice đầu tiên.
    void writeVideo(const uint8_t* annexB, size_t len, int64_t ptsUs, int64_t dtsUs, bool keyframe,
                    const std::vector<uint8_t>* seiNal = nullptr);
    void writeAudio(const uint8_t* data, size_t len, int64_t ptsUs);

    // Danh sách NAL tham số (không có start code), theo thứ tự VPS, SPS, PPS.
    void setVideoParameterSets(const std::vector<std::vector<uint8_t>>& nals);

    const Config& config() const { return cfg_; }

private:
    void writePsi(int64_t nowUs);
    void writePes(uint16_t pid, uint8_t streamId, const uint8_t* data, size_t len,
                  int64_t pts90, int64_t dts90, bool withPcr, int64_t pcr90, bool randomAccess,
                  bool boundedLength);
    void writeSection(uint16_t pid, const std::vector<uint8_t>& section);
    std::vector<uint8_t> buildPat() const;
    std::vector<uint8_t> buildPmt() const;

    Config cfg_;
    PacketSink sink_;
    uint8_t cc_[0x2000] = {};
    bool psiSent_ = false;
    int64_t lastPsiUs_ = 0;
    std::vector<std::vector<uint8_t>> paramSets_;
    std::vector<uint8_t> scratch_;
};

// Tiện ích Annex-B
namespace annexb {
// Tách danh sách NAL (con trỏ vào buffer gốc, không có start code)
struct Nal { const uint8_t* data; size_t size; };
std::vector<Nal> split(const uint8_t* buf, size_t len);
int h264Type(const Nal& n);   // nal_unit_type H.264
int hevcType(const Nal& n);   // nal_unit_type HEVC
// Chuyển AVCC/HVCC (length-prefix) sang Annex-B
std::vector<uint8_t> fromLengthPrefixed(const uint8_t* buf, size_t len, int lengthSize = 4);
} // namespace annexb

uint32_t crc32Mpeg(const uint8_t* data, size_t len);

} // namespace srtkit
