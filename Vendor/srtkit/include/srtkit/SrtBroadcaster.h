// SrtBroadcaster: điều phối tối đa 5 kết nối SRT song song từ một encoder chung.
//  - Fan-out frame đã encode tới mọi kết nối (mỗi kết nối mux TS theo ContentMode riêng)
//  - Gộp đề xuất ABR: bitrate/FPS encoder = mức thấp nhất trong các kết nối đang bật ABR
//  - Chèn SEI NTP timecode (tùy chọn)
//  - Pause / Standby: giữ kết nối, tạm ngưng kiểm tra idle
//  - Theo dõi mạng, thống kê mỗi giây
#pragma once

#include <atomic>
#include <map>
#include <memory>
#include <mutex>
#include <thread>
#include <vector>

#include "srtkit/SrtConnection.h"
#include "srtkit/Timecode.h"
#include "srtkit/Types.h"

namespace srtkit {

class SrtBroadcaster {
public:
    static constexpr int kMaxConnections = 5;

    SrtBroadcaster(const StreamParams& params, BroadcasterCallbacks cb);
    ~SrtBroadcaster();

    // Trả về id kết nối hoặc -1 nếu đã đủ 5 / đang chạy.
    int addConnection(const ConnectionConfig& cfg, const ReconnectPolicy& policy = {});
    bool removeConnection(int id);

    // standby = true: bắt đầu ở chế độ Standby (đã kết nối nhưng đang Pause)
    void start(bool standby = false);
    void stop();
    bool isRunning() const { return running_; }

    // Bật/tắt riêng từng kết nối khi đang live
    bool startConnection(int id);
    bool stopConnection(int id);

    // ---- dữ liệu từ encoder ----
    void setVideoParameterSets(const std::vector<std::vector<uint8_t>>& nals);  // VPS?, SPS, PPS – không start code
    void pushVideo(const uint8_t* annexB, size_t len, int64_t ptsUs, int64_t dtsUs, bool keyframe);
    void pushAudio(const uint8_t* data, size_t len, int64_t ptsUs);

    // ---- điều khiển ----
    void setNetworkAvailable(bool available);
    void setPaused(bool paused);          // Pause/Standby: app phải đưa khung đen/overlay + PCM câm
    bool paused() const { return paused_; }
    void setTargetBitrate(int bps);       // người dùng đổi bitrate -> trần mới cho ABR
    int currentBitrate() const { return appliedBitrate_; }
    int currentFps() const { return appliedFps_; }

    std::vector<ConnectionStats> stats() const;
    const StreamParams& params() const { return params_; }

private:
    void recomputeAbr();
    void requestKeyframeThrottled();

    StreamParams params_;
    BroadcasterCallbacks cb_;
    mutable std::mutex mtx_;
    std::map<int, std::unique_ptr<SrtConnection>> conns_;
    std::map<int, ReconnectPolicy> policies_;
    int nextId_ = 1;
    std::atomic<bool> running_{false};
    std::atomic<bool> paused_{false};
    std::atomic<bool> network_{true};

    std::mutex abrValsMtx_;
    std::map<int, std::pair<int, int>> abrVals_;   // id -> (bitrate, fps) đề xuất; 0 = không ràng buộc
    std::mutex abrMtx_;
    int appliedBitrate_ = 0;
    int appliedFps_ = 0;
    std::atomic<int64_t> lastKeyReqMs_{0};

    NtpClock ntp_;
    bool haveTimeBase_ = false;
    int64_t basePtsUs_ = 0, baseWallUs_ = 0, lastNtpOffset_ = 0;

    std::thread statsTh_;
    std::atomic<bool> statsRun_{false};
};

} // namespace srtkit
