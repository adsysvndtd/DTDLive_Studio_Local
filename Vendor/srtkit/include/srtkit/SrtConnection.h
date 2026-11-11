// Một đích SRT: tự kết nối / nối lại, mux TS riêng theo ContentMode, hàng đợi gửi có giới hạn,
// thống kê và ABR riêng cho đích này.
#pragma once

#include <atomic>
#include <condition_variable>
#include <deque>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "srtkit/AbrController.h"
#include "srtkit/TsMuxer.h"
#include "srtkit/Types.h"

namespace srtkit {

class SrtConnection {
public:
    struct Hooks {
        std::function<void(int id, ConnState, const std::string&)> onState;
        std::function<void(int id, int bitrate, int fps)> onAbr;   // ABR của kết nối đổi đề xuất
        std::function<void(int id)> onNeedKeyframe;
    };

    SrtConnection(int id, const ConnectionConfig& cfg, const ReconnectPolicy& policy,
                  const StreamParams& params, Hooks hooks);
    ~SrtConnection();

    void start();
    void stop();
    bool running() const { return running_; }

    void setVideoParameterSets(const std::vector<std::vector<uint8_t>>& nals);
    void pushVideo(const uint8_t* annexB, size_t len, int64_t ptsUs, int64_t dtsUs, bool key,
                   const std::vector<uint8_t>* sei);
    void pushAudio(const uint8_t* data, size_t len, int64_t ptsUs);

    void setNetworkAvailable(bool available);
    void setMaxBitrate(int bps);
    void setSuspendIdle(bool s) { suspendIdle_ = s; }   // đang Pause/Standby thì không tính idle

    ConnectionStats stats() const;
    const ConnectionConfig& config() const { return cfg_; }
    int id() const { return id_; }
    ConnState state() const { return state_; }
    // Đề xuất ABR hiện tại (0 = ABR tắt hoặc chưa kết nối)
    int abrBitrate() const { return abrBitrate_; }
    int abrFps() const { return abrFps_; }

private:
    struct Chunk { std::vector<uint8_t> data; int64_t enqMs; };

    void run();
    int openSocket(std::string& err);      // trả về SRTSOCKET hoặc -1
    std::string sendLoop(int sock);        // trả về lý do ngắt
    void setState(ConnState s, const std::string& info = {});
    void onTsPacket(const uint8_t* p);
    void flushPending();
    bool waitFor(int ms);                  // ngủ có thể bị ngắt bởi stop()/đổi mạng; trả về false nếu stop

    const int id_;
    ConnectionConfig cfg_;
    ReconnectPolicy policy_;
    StreamParams params_;
    Hooks hooks_;

    std::atomic<bool> running_{false};
    std::atomic<bool> connected_{false};
    std::atomic<bool> network_{true};
    std::atomic<bool> suspendIdle_{false};
    std::atomic<ConnState> state_{ConnState::Idle};
    std::atomic<int> sock_{-1};
    std::thread th_;

    // Mux + hàng đợi (bảo vệ bởi mtx_)
    mutable std::mutex mtx_;
    std::condition_variable cv_;
    std::unique_ptr<TsMuxer> mux_;
    std::vector<uint8_t> pending_;
    std::deque<Chunk> queue_;
    bool waitKey_ = true;
    std::atomic<int64_t> lastPushMs_{0};

    // Ngủ / đánh thức
    std::mutex sleepMtx_;
    std::condition_variable sleepCv_;

    // ABR
    std::unique_ptr<AbrController> abr_;
    std::atomic<int> abrBitrate_{0};
    std::atomic<int> abrFps_{0};

    // Thống kê
    mutable std::mutex statsMtx_;
    ConnectionStats stats_;
    int64_t connectedAtMs_ = 0;
    uint64_t bytesBase_ = 0, lastSockBytes_ = 0;   // cộng dồn byte qua các lần nối lại
};

int64_t monotonicMs();

} // namespace srtkit
