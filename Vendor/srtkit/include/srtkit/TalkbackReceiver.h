// Talkback: nhận luồng audio trả về (return feed) qua SRT, tách AAC/Opus từ TS,
// phát theo nhịp PTS sau một bộ đệm cố định (Larix: tb[][buffer]).
// SRT mode: Caller = "pull" (nguồn ở chế độ Listen), Listener (nguồn đẩy tới máy), Rendezvous.
#pragma once

#include <atomic>
#include <condition_variable>
#include <deque>
#include <functional>
#include <mutex>
#include <string>
#include <thread>

#include "srtkit/TsDemuxer.h"
#include "srtkit/Types.h"

namespace srtkit {

class TalkbackReceiver {
public:
    struct Config {
        SrtOptions srt;           // mặc định Caller (pull)
        int bufferMs = 500;       // độ trễ phát cố định để chống jitter
        int reconnectDelayMs = 2000;
    };
    struct Callbacks {
        std::function<void(ConnState, const std::string&)> onState;
        // Gọi đúng nhịp phát (thread nội bộ). App giải mã (AudioConverter) rồi đưa vào AVAudioEngine.
        std::function<void(const DemuxedAudioFrame&)> onAudio;
        TsDemuxer::VideoSink onVideo;
        std::function<void(int)> onListening;
    };

    TalkbackReceiver(const Config& cfg, Callbacks cb);
    ~TalkbackReceiver();

    void start();
    void stop();
    ConnState state() const { return state_; }

    /// Receive-side link quality (SRT counters since connect + demuxer losses).
    struct LinkStats {
        bool connected = false;
        int64_t pktRecv = 0, pktLoss = 0, pktDrop = 0, pktRetrans = 0;
        double rttMs = 0, mbpsRecv = 0, mbpsBandwidth = 0;
        int msRcvBuf = 0, latencyMs = 0;
        uint64_t ccErrors = 0, videoDropped = 0;
    };
    LinkStats linkStats();
    uint64_t framesReceived() const { return framesIn_; }
    uint64_t framesLate() const { return framesLate_; }

private:
    void netLoop();
    void playLoop();
    int open(std::string& err);
    void setState(ConnState s, const std::string& info = {});

    Config cfg_;
    Callbacks cb_;
    std::atomic<bool> running_{false};
    std::atomic<ConnState> state_{ConnState::Idle};
    std::atomic<int> sock_{-1};
    std::atomic<uint64_t> ccErrors_{0}, videoDropped_{0};
    std::thread netTh_, playTh_;

    std::mutex qMtx_;
    std::condition_variable qCv_;
    std::deque<DemuxedAudioFrame> q_;
    bool clockSet_ = false;
    int64_t clockBasePts_ = 0, clockBaseMs_ = 0;
    std::atomic<uint64_t> framesIn_{0}, framesLate_{0};
};

} // namespace srtkit
