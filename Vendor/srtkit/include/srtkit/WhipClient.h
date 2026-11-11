// SRTKit – WHIP (WebRTC-HTTP ingestion) phía gửi: ICE (controlling) + DTLS-SRTP (mbedTLS) + RTP H.264/Opus.
// Phần HTTP (POST offer / DELETE resource) do tầng app làm; lớp này tạo offer, nhận answer và đẩy media.
#pragma once

#include <atomic>
#include <cstdint>
#include <functional>
#include <memory>
#include <string>
#include <vector>

namespace srtkit {

struct WhipStats {
    uint64_t bytesSent = 0;
    uint64_t packetsSent = 0;
    uint64_t nacksReceived = 0;
    uint64_t retransmitted = 0;
    uint64_t keyframeRequests = 0;
    double rttMs = 0;
    double fractionLost = 0;   // 0..1, từ RTCP RR
};

class WhipClient {
public:
    enum class State { Idle, Checking, Handshaking, Connected, Failed, Closed };

    struct Options {
        bool video = true;
        bool audio = true;
        std::string h264ProfileLevelId = "42e01f";
        int audioChannels = 2;
        int mtu = 1200;
    };

    explicit WhipClient(const Options& o);
    ~WhipClient();

    /// SDP offer (sendonly, BUNDLE, rtcp-mux). Gọi một lần trước setAnswer.
    std::string createOffer();
    /// Nhận SDP answer; trả lỗi rỗng nếu hợp lệ
    std::string setAnswer(const std::string& sdp);
    /// Bắt đầu ICE → DTLS → gửi media (luồng riêng)
    bool start();
    void stop();

    /// NALU dạng AVCC (độ dài 4 byte). sps/pps gửi kèm trước mỗi keyframe.
    void sendVideo(const uint8_t* avcc, size_t len, int64_t ptsUs, bool keyframe,
                   const std::vector<std::vector<uint8_t>>& sps, const std::vector<std::vector<uint8_t>>& pps);
    /// Một gói Opus 20 ms
    void sendOpus(const uint8_t* data, size_t len, int64_t ptsUs);

    std::function<void(State, const std::string&)> onState;
    std::function<void()> onKeyframeRequest;

    State state() const;
    WhipStats stats() const;

    struct Impl;
private:
    std::unique_ptr<Impl> d;
};

// tiện ích kiểm thử
namespace whip_detail {
uint32_t crc32(const uint8_t* p, size_t n);
}

} // namespace srtkit
