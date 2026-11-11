#include "srtkit/SrtBroadcaster.h"

#include <chrono>

#include <srt/srt.h>

namespace srtkit {

namespace {
std::once_flag gSrtInit;
} // namespace

SrtBroadcaster::SrtBroadcaster(const StreamParams& params, BroadcasterCallbacks cb)
    : params_(params), cb_(std::move(cb)) {
    std::call_once(gSrtInit, [] { srt_startup(); srt_setloglevel(3 /*LOG_ERR*/); });
    appliedBitrate_ = params_.videoBitrateBps;
    appliedFps_ = params_.fps;
}

SrtBroadcaster::~SrtBroadcaster() { stop(); }

int SrtBroadcaster::addConnection(const ConnectionConfig& cfg, const ReconnectPolicy& policy) {
    std::lock_guard<std::mutex> l(mtx_);
    if (static_cast<int>(conns_.size()) >= kMaxConnections) return -1;
    int id = nextId_++;
    SrtConnection::Hooks hooks;
    hooks.onState = [this](int cid, ConnState s, const std::string& info) {
        if (cb_.onState) cb_.onState(cid, s, info);
    };
    hooks.onAbr = [this](int cid, int bitrate, int fps) {
        {
            std::lock_guard<std::mutex> g(abrValsMtx_);
            abrVals_[cid] = {bitrate, fps};
        }
        recomputeAbr();
    };
    hooks.onNeedKeyframe = [this](int) { requestKeyframeThrottled(); };
    auto c = std::make_unique<SrtConnection>(id, cfg, policy, params_, hooks);
    c->setNetworkAvailable(network_);
    c->setSuspendIdle(paused_);
    if (running_) c->start();
    conns_[id] = std::move(c);
    policies_[id] = policy;
    return id;
}

bool SrtBroadcaster::removeConnection(int id) {
    std::unique_ptr<SrtConnection> c;
    {
        std::lock_guard<std::mutex> l(mtx_);
        auto it = conns_.find(id);
        if (it == conns_.end()) return false;
        c = std::move(it->second);
        conns_.erase(it);
        policies_.erase(id);
    }
    c->stop();  // ngoài lock để tránh deadlock với hook
    {
        std::lock_guard<std::mutex> g(abrValsMtx_);
        abrVals_.erase(id);
    }
    recomputeAbr();
    return true;
}

void SrtBroadcaster::start(bool standby) {
    if (running_.exchange(true)) return;
    setPaused(standby);
    if (params_.insertNtpSei && !params_.ntpHost.empty()) ntp_.start(params_.ntpHost);
    haveTimeBase_ = false;
    {
        std::lock_guard<std::mutex> l(mtx_);
        for (auto& kv : conns_) kv.second->start();
    }
    statsRun_ = true;
    statsTh_ = std::thread([this] {
        while (statsRun_) {
            for (int i = 0; i < 10 && statsRun_; ++i) std::this_thread::sleep_for(std::chrono::milliseconds(100));
            if (!statsRun_) break;
            if (cb_.onStats) cb_.onStats(stats());
        }
    });
}

void SrtBroadcaster::stop() {
    if (!running_.exchange(false)) return;
    statsRun_ = false;
    if (statsTh_.joinable()) statsTh_.join();
    std::vector<SrtConnection*> list;
    {
        std::lock_guard<std::mutex> l(mtx_);
        for (auto& kv : conns_) list.push_back(kv.second.get());
    }
    for (auto* c : list) c->stop();
    ntp_.stop();
    {
        std::lock_guard<std::mutex> g(abrValsMtx_);
        abrVals_.clear();
    }
    std::lock_guard<std::mutex> a(abrMtx_);
    appliedBitrate_ = params_.videoBitrateBps;
    appliedFps_ = params_.fps;
}

bool SrtBroadcaster::startConnection(int id) {
    std::lock_guard<std::mutex> l(mtx_);
    auto it = conns_.find(id);
    if (it == conns_.end() || !running_) return false;
    it->second->start();
    return true;
}

bool SrtBroadcaster::stopConnection(int id) {
    SrtConnection* c = nullptr;
    {
        std::lock_guard<std::mutex> l(mtx_);
        auto it = conns_.find(id);
        if (it == conns_.end()) return false;
        c = it->second.get();
    }
    c->stop();
    return true;
}

void SrtBroadcaster::setVideoParameterSets(const std::vector<std::vector<uint8_t>>& nals) {
    std::lock_guard<std::mutex> l(mtx_);
    for (auto& kv : conns_) kv.second->setVideoParameterSets(nals);
}

void SrtBroadcaster::pushVideo(const uint8_t* annexB, size_t len, int64_t ptsUs, int64_t dtsUs, bool keyframe) {
    if (!running_) return;
    std::vector<uint8_t> sei;
    if (params_.insertNtpSei) {
        if (!haveTimeBase_) {
            basePtsUs_ = ptsUs;
            baseWallUs_ = ntp_.nowUnixUs();
            lastNtpOffset_ = ntp_.offsetUs();
            haveTimeBase_ = true;
        }
        // NTP chỉ đồng bộ xong sau vài trăm ms -> cập nhật lại mốc khi có offset mới
        int64_t off = ntp_.offsetUs();
        if (off != lastNtpOffset_) {
            baseWallUs_ += off - lastNtpOffset_;
            lastNtpOffset_ = off;
        }
        sei = buildTimecodeSei(params_.videoCodec, baseWallUs_ + (ptsUs - basePtsUs_));
    }
    std::lock_guard<std::mutex> l(mtx_);
    for (auto& kv : conns_)
        kv.second->pushVideo(annexB, len, ptsUs, dtsUs, keyframe, sei.empty() ? nullptr : &sei);
}

void SrtBroadcaster::pushAudio(const uint8_t* data, size_t len, int64_t ptsUs) {
    if (!running_) return;
    std::lock_guard<std::mutex> l(mtx_);
    for (auto& kv : conns_) kv.second->pushAudio(data, len, ptsUs);
}

void SrtBroadcaster::setNetworkAvailable(bool available) {
    network_ = available;
    std::lock_guard<std::mutex> l(mtx_);
    for (auto& kv : conns_) kv.second->setNetworkAvailable(available);
}

void SrtBroadcaster::setPaused(bool paused) {
    paused_ = paused;
    std::lock_guard<std::mutex> l(mtx_);
    for (auto& kv : conns_) kv.second->setSuspendIdle(paused);
}

void SrtBroadcaster::setTargetBitrate(int bps) {
    params_.videoBitrateBps = bps;
    {
        std::lock_guard<std::mutex> l(mtx_);
        for (auto& kv : conns_) kv.second->setMaxBitrate(bps);
    }
    recomputeAbr();
}

void SrtBroadcaster::recomputeAbr() {
    int b = 0, f = 0;
    {
        std::lock_guard<std::mutex> g(abrValsMtx_);
        for (auto& kv : abrVals_) {
            if (kv.second.first <= 0) continue;
            b = b == 0 ? kv.second.first : std::min(b, kv.second.first);
            f = f == 0 ? kv.second.second : std::min(f, kv.second.second);
        }
    }
    if (b == 0) b = params_.videoBitrateBps;
    if (f == 0) f = params_.fps;
    b = std::min(b, params_.videoBitrateBps);
    bool bChanged = false, fChanged = false;
    {
        std::lock_guard<std::mutex> a(abrMtx_);
        if (b != appliedBitrate_) { appliedBitrate_ = b; bChanged = true; }
        if (f != appliedFps_) { appliedFps_ = f; fChanged = true; }
    }
    if (bChanged && cb_.setEncoderBitrate) cb_.setEncoderBitrate(b);
    if (fChanged && cb_.setEncoderFps) cb_.setEncoderFps(f);
}

void SrtBroadcaster::requestKeyframeThrottled() {
    int64_t now = monotonicMs();
    int64_t last = lastKeyReqMs_.load();
    if (now - last < 500) return;  // tối đa 2 lần/giây
    if (!lastKeyReqMs_.compare_exchange_strong(last, now)) return;
    if (cb_.requestKeyframe) cb_.requestKeyframe();
}

std::vector<ConnectionStats> SrtBroadcaster::stats() const {
    std::vector<ConnectionStats> out;
    std::lock_guard<std::mutex> l(mtx_);
    for (auto& kv : conns_) out.push_back(kv.second->stats());
    return out;
}

} // namespace srtkit
