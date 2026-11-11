#include "srtkit/SrtConnection.h"

#include <chrono>
#include <cstring>

#include <netdb.h>
#include <netinet/in.h>
#include <sys/socket.h>

#include <srt/srt.h>

namespace srtkit {

int64_t monotonicMs() {
    return std::chrono::duration_cast<std::chrono::milliseconds>(
               std::chrono::steady_clock::now().time_since_epoch()).count();
}

const char* toString(ConnState s) {
    switch (s) {
    case ConnState::Idle: return "idle";
    case ConnState::Connecting: return "connecting";
    case ConnState::Listening: return "listening";
    case ConnState::Connected: return "connected";
    case ConnState::Reconnecting: return "reconnecting";
    case ConnState::WaitingNetwork: return "waiting_network";
    case ConnState::Failed: return "failed";
    }
    return "?";
}

namespace {

bool resolve(const std::string& host, int port, bool passive, sockaddr_storage& out, socklen_t& outLen, std::string& err) {
    addrinfo hints{}, *res = nullptr;
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_DGRAM;
    if (passive) hints.ai_flags = AI_PASSIVE;
    std::string p = std::to_string(port);
    int rc = getaddrinfo(host.empty() ? nullptr : host.c_str(), p.c_str(), &hints, &res);
    if (rc != 0 || !res) { err = std::string("resolve ") + host + ": " + gai_strerror(rc); return false; }
    // Ưu tiên IPv4 khi bind passive không có host
    addrinfo* pick = res;
    if (passive && host.empty())
        for (addrinfo* a = res; a; a = a->ai_next) if (a->ai_family == AF_INET) { pick = a; break; }
    std::memcpy(&out, pick->ai_addr, pick->ai_addrlen);
    outLen = static_cast<socklen_t>(pick->ai_addrlen);
    freeaddrinfo(res);
    return true;
}

std::string lastSrtError() {
    const char* e = srt_getlasterror_str();
    return e ? e : "unknown";
}

} // namespace

// ---------------------------------------------------------------------------
SrtConnection::SrtConnection(int id, const ConnectionConfig& cfg, const ReconnectPolicy& policy,
                             const StreamParams& params, Hooks hooks)
    : id_(id), cfg_(cfg), policy_(policy), params_(params), hooks_(std::move(hooks)) {
    TsMuxer::Config mc;
    mc.hasVideo = cfg_.content != ContentMode::AudioOnly;
    mc.hasAudio = cfg_.content != ContentMode::VideoOnly && params_.hasAudio;
    mc.videoCodec = params_.videoCodec;
    mc.audioCodec = params_.audioCodec;
    mc.audioSampleRate = params_.audioSampleRate;
    mc.audioChannels = params_.audioChannels;
    mc.aacProfile = params_.aacProfile;
    mux_ = std::make_unique<TsMuxer>(mc, [this](const uint8_t* p) { onTsPacket(p); });
    if (cfg_.abr != AbrMode::Off && mc.hasVideo)
        abr_ = std::make_unique<AbrController>(cfg_.abr, params_.videoBitrateBps, params_.fps, cfg_.variableFps);
    stats_.id = id_;
    stats_.name = cfg_.name;
}

SrtConnection::~SrtConnection() { stop(); }

void SrtConnection::start() {
    if (running_) return;
    running_ = true;
    th_ = std::thread([this] { run(); });
}

void SrtConnection::stop() {
    if (!running_.exchange(false)) { if (th_.joinable()) th_.join(); return; }
    { std::lock_guard<std::mutex> l(sleepMtx_); }
    sleepCv_.notify_all();
    cv_.notify_all();
    int s = sock_.load();
    if (s >= 0) srt_close(s);   // phá các lời gọi chặn (connect/accept/send)
    if (th_.joinable()) th_.join();
    setState(ConnState::Idle, "stopped");
}

void SrtConnection::setNetworkAvailable(bool available) {
    network_ = available;
    { std::lock_guard<std::mutex> l(sleepMtx_); }
    sleepCv_.notify_all();  // có mạng lại -> thử ngay
}

void SrtConnection::setMaxBitrate(int bps) {
    std::lock_guard<std::mutex> l(mtx_);
    params_.videoBitrateBps = bps;
    if (abr_) {
        abr_->setMaxBitrate(bps);
        if (connected_) { abrBitrate_ = abr_->bitrate(); abrFps_ = abr_->fps(); }
    }
}

bool SrtConnection::waitFor(int ms) {
    std::unique_lock<std::mutex> l(sleepMtx_);
    bool wasNet = network_;
    sleepCv_.wait_for(l, std::chrono::milliseconds(ms), [&] { return !running_ || (network_ && !wasNet); });
    return running_;
}

void SrtConnection::setState(ConnState s, const std::string& info) {
    ConnState old = state_.exchange(s);
    {
        std::lock_guard<std::mutex> l(statsMtx_);
        stats_.state = s;
        if (!info.empty() && s != ConnState::Connected) stats_.lastError = info;
    }
    if (old != s && hooks_.onState) hooks_.onState(id_, s, info);
}

// ---------------------------------------------------------------------------
// Đường dữ liệu (thread của app)
// ---------------------------------------------------------------------------
void SrtConnection::setVideoParameterSets(const std::vector<std::vector<uint8_t>>& nals) {
    std::lock_guard<std::mutex> l(mtx_);
    mux_->setVideoParameterSets(nals);
}

void SrtConnection::onTsPacket(const uint8_t* p) {
    pending_.insert(pending_.end(), p, p + 188);
    if (pending_.size() >= static_cast<size_t>(cfg_.srt.payloadSize)) flushPending();
}

void SrtConnection::flushPending() {
    if (pending_.empty()) return;
    queue_.push_back({std::move(pending_), monotonicMs()});
    pending_.clear();
    pending_.reserve(cfg_.srt.payloadSize);
}

void SrtConnection::pushVideo(const uint8_t* annexB, size_t len, int64_t ptsUs, int64_t dtsUs, bool key,
                              const std::vector<uint8_t>* sei) {
    if (cfg_.content == ContentMode::AudioOnly) return;
    lastPushMs_ = monotonicMs();
    if (!connected_) return;
    bool needKey = false;
    {
        std::lock_guard<std::mutex> l(mtx_);
        if (waitKey_ && !key) {
            std::lock_guard<std::mutex> sl(statsMtx_);
            ++stats_.framesDropped;
            return;
        }
        waitKey_ = false;
        // Tràn hàng đợi: bỏ toàn bộ, chờ keyframe kế tiếp
        if (!queue_.empty() && lastPushMs_ - queue_.front().enqMs > cfg_.queueMs) {
            queue_.clear();
            pending_.clear();
            if (!key) {
                waitKey_ = true;
                needKey = true;
                std::lock_guard<std::mutex> sl(statsMtx_);
                ++stats_.framesDropped;
            }
        }
        if (!waitKey_) {
            mux_->writeVideo(annexB, len, ptsUs, dtsUs, key, sei);
            flushPending();  // gửi ngay cuối mỗi frame để giảm trễ
        }
    }
    cv_.notify_one();
    if (needKey && hooks_.onNeedKeyframe) hooks_.onNeedKeyframe(id_);
}

void SrtConnection::pushAudio(const uint8_t* data, size_t len, int64_t ptsUs) {
    if (cfg_.content == ContentMode::VideoOnly || !params_.hasAudio) return;
    if (cfg_.content == ContentMode::AudioOnly) lastPushMs_ = monotonicMs();
    if (!connected_) return;
    {
        std::lock_guard<std::mutex> l(mtx_);
        // Với luồng có video: chưa có keyframe đầu tiên thì chưa gửi audio để player khởi động sạch
        if (waitKey_ && cfg_.content == ContentMode::VideoAudio) return;
        if (cfg_.content == ContentMode::AudioOnly && !queue_.empty() &&
            monotonicMs() - queue_.front().enqMs > cfg_.queueMs) {
            queue_.clear();
            pending_.clear();
        }
        mux_->writeAudio(data, len, ptsUs);
        flushPending();
    }
    cv_.notify_one();
}

// ---------------------------------------------------------------------------
// Thread kết nối
// ---------------------------------------------------------------------------
int SrtConnection::openSocket(std::string& err) {
    const SrtOptions& o = cfg_.srt;
    SRTSOCKET s = srt_create_socket();
    if (s == SRT_INVALID_SOCK) { err = lastSrtError(); return -1; }
    sock_ = s;

    auto setInt = [&](SRT_SOCKOPT opt, int v) { srt_setsockflag(s, opt, &v, sizeof(v)); };
    auto setI64 = [&](SRT_SOCKOPT opt, int64_t v) { srt_setsockflag(s, opt, &v, sizeof(v)); };
    auto setBool = [&](SRT_SOCKOPT opt, bool v) { srt_setsockflag(s, opt, &v, sizeof(v)); };

    SRT_TRANSTYPE tt = SRTT_LIVE;
    srt_setsockflag(s, SRTO_TRANSTYPE, &tt, sizeof(tt));
    setBool(SRTO_SENDER, true);
    setInt(SRTO_LATENCY, o.latencyMs);
    setInt(SRTO_PAYLOADSIZE, o.payloadSize);
    setInt(SRTO_CONNTIMEO, o.connectTimeoutMs);
    setBool(SRTO_TLPKTDROP, true);
    if (o.maxBwBytesPerSec > 0) {
        setI64(SRTO_MAXBW, o.maxBwBytesPerSec);
    } else if (o.maxBwBytesPerSec == 0) {
        // Tự động: ước lượng input, tối thiểu = bitrate encoder, + 25% cho retrans
        int64_t audio = params_.hasAudio ? 128000 : 0;
        setI64(SRTO_MAXBW, 0);
        setI64(SRTO_INPUTBW, 0);
        setI64(SRTO_MININPUTBW, (params_.videoBitrateBps + audio) / 8);
        setInt(SRTO_OHEADBW, 25);
    } else {
        setI64(SRTO_MAXBW, -1);
    }
    if (!o.passphrase.empty()) {
        if (srt_setsockflag(s, SRTO_PASSPHRASE, o.passphrase.data(), static_cast<int>(o.passphrase.size())) == SRT_ERROR) {
            err = lastSrtError();
            srt_close(s); sock_ = -1; return -1;
        }
        setInt(SRTO_PBKEYLEN, o.pbKeyLen);
    }
    if (!o.streamId.empty())
        srt_setsockflag(s, SRTO_STREAMID, o.streamId.data(), static_cast<int>(o.streamId.size()));

    sockaddr_storage sa{};
    socklen_t saLen = 0;

    if (o.mode == SrtMode::Caller) {
        setState(ConnState::Connecting, o.host + ":" + std::to_string(o.port));
        if (!resolve(o.host, o.port, false, sa, saLen, err)) { srt_close(s); sock_ = -1; return -1; }
        if (srt_connect(s, reinterpret_cast<sockaddr*>(&sa), saLen) == SRT_ERROR) {
            err = "connect: " + lastSrtError();
            int r = srt_getrejectreason(s);
            if (r != SRT_REJ_UNKNOWN) err += std::string(" (") + srt_rejectreason_str(r) + ")";
            srt_close(s); sock_ = -1; return -1;
        }
        return s;
    }

    if (o.mode == SrtMode::Rendezvous) {
        setState(ConnState::Connecting, "rendezvous " + o.host + ":" + std::to_string(o.port));
        setBool(SRTO_RENDEZVOUS, true);
        sockaddr_storage local{};
        socklen_t localLen = 0;
        if (!resolve(o.host, o.port, false, sa, saLen, err)) { srt_close(s); sock_ = -1; return -1; }
        std::string bindHost = sa.ss_family == AF_INET6 ? "::" : "0.0.0.0";
        if (!resolve(bindHost, o.localPort ? o.localPort : o.port, true, local, localLen, err) ||
            srt_bind(s, reinterpret_cast<sockaddr*>(&local), localLen) == SRT_ERROR) {
            if (err.empty()) err = "bind: " + lastSrtError();
            srt_close(s); sock_ = -1; return -1;
        }
        if (srt_connect(s, reinterpret_cast<sockaddr*>(&sa), saLen) == SRT_ERROR) {
            err = "rendezvous: " + lastSrtError();
            srt_close(s); sock_ = -1; return -1;
        }
        return s;
    }

    // Listener: bind + chờ một phía kéo luồng; sau khi accept thì đóng socket nghe.
    setState(ConnState::Listening, ":" + std::to_string(o.port));
    if (!resolve(o.host, o.port, true, sa, saLen, err)) { srt_close(s); sock_ = -1; return -1; }
    if (srt_bind(s, reinterpret_cast<sockaddr*>(&sa), saLen) == SRT_ERROR || srt_listen(s, 1) == SRT_ERROR) {
        err = "listen: " + lastSrtError();
        srt_close(s); sock_ = -1; return -1;
    }
    int eid = srt_epoll_create();
    int ev = SRT_EPOLL_IN | SRT_EPOLL_ERR;
    srt_epoll_add_usock(eid, s, &ev);
    SRTSOCKET acc = SRT_INVALID_SOCK;
    while (running_) {
        SRTSOCKET rd[1]; int rn = 1;
        int n = srt_epoll_wait(eid, rd, &rn, nullptr, nullptr, 500, nullptr, nullptr, nullptr, nullptr);
        if (n > 0) {
            sockaddr_storage peer{}; int pl = sizeof(peer);
            acc = srt_accept(s, reinterpret_cast<sockaddr*>(&peer), &pl);
            break;
        }
        if (n < 0 && srt_getlasterror(nullptr) != SRT_ETIMEOUT) break;
    }
    srt_epoll_release(eid);
    srt_close(s);
    sock_ = -1;
    if (acc == SRT_INVALID_SOCK) { err = running_ ? "accept: " + lastSrtError() : "stopped"; return -1; }
    sock_ = acc;
    return acc;
}

std::string SrtConnection::sendLoop(int sock) {
    int64_t lastStats = monotonicMs();
    int64_t lastAckMs = lastStats;
    if (abr_) abr_->reset(lastStats);
    SRT_TRACEBSTATS perf{};
    while (running_) {
        Chunk c;
        bool have = false;
        {
            std::unique_lock<std::mutex> l(mtx_);
            cv_.wait_for(l, std::chrono::milliseconds(100), [&] { return !queue_.empty() || !running_; });
            if (!queue_.empty()) { c = std::move(queue_.front()); queue_.pop_front(); have = true; }
        }
        if (have) {
            if (srt_sendmsg2(sock, reinterpret_cast<const char*>(c.data.data()), static_cast<int>(c.data.size()), nullptr) == SRT_ERROR)
                return "send: " + lastSrtError();
        }
        SRT_SOCKSTATUS st = srt_getsockstate(sock);
        if (st != SRTS_CONNECTED) return "socket state " + std::to_string(static_cast<int>(st));

        int64_t now = monotonicMs();
        if (now - lastStats >= 1000) {
            lastStats = now;
            if (srt_bstats(sock, &perf, 1) == 0) {
                {
                    std::lock_guard<std::mutex> l(statsMtx_);
                    stats_.uptimeMs = now - connectedAtMs_;
                    stats_.bytesSent = bytesBase_ + perf.byteSentUniqueTotal;
                    lastSockBytes_ = perf.byteSentUniqueTotal;
                    stats_.sendKbps = perf.mbpsSendRate * 1000.0;
                    stats_.rttMs = perf.msRTT;
                    stats_.bandwidthMbps = perf.mbpsBandwidth;
                    stats_.pktSent = perf.pktSentTotal;
                    stats_.pktLost = perf.pktSndLossTotal;
                    stats_.pktRetrans = perf.pktRetransTotal;
                    stats_.pktDropped = perf.pktSndDropTotal;
                    stats_.msSndBuf = perf.msSndBuf;
                }
                if (abr_) {
                    bool changed;
                    {
                        std::lock_guard<std::mutex> l(mtx_);
                        changed = abr_->onSample({now, perf.pktSentTotal, perf.pktSndLossTotal, perf.pktSndDropTotal});
                        abrBitrate_ = abr_->bitrate();
                        abrFps_ = abr_->fps();
                    }
                    if (changed && hooks_.onAbr) hooks_.onAbr(id_, abrBitrate_, abrFps_);
                }
                // Treo: phía nhận không còn ACK (dữ liệu gửi đi mà không được xác nhận)
                if (perf.pktRecvACK > 0 || perf.pktSent == 0) lastAckMs = now;
                if (policy_.unsentTimeoutMs > 0 &&
                    (now - lastAckMs > policy_.unsentTimeoutMs || perf.msSndBuf > policy_.unsentTimeoutMs))
                    return "unsent timeout (" + std::to_string(now - lastAckMs) + " ms không có ACK)";
            }
            if (policy_.idleTimeoutMs > 0 && !suspendIdle_ && now - lastPushMs_ > policy_.idleTimeoutMs)
                return "idle";
        }
    }
    return "stopped";
}

void SrtConnection::run() {
    int attempts = 0;
    while (running_) {
        if (policy_.checkNetwork && !network_) {
            setState(ConnState::WaitingNetwork, "no network");
            if (!waitFor(policy_.noNetworkReconnectDelayMs)) break;
            continue;
        }
        std::string err;
        int s = openSocket(err);
        if (!running_) { if (s >= 0) srt_close(s); break; }
        if (s < 0) {
            ++attempts;
            if (policy_.maxAttempts > 0 && attempts >= policy_.maxAttempts) {
                setState(ConnState::Failed, err);
                running_ = false;
                break;
            }
            setState(ConnState::Reconnecting, err);
            if (!waitFor(network_ ? policy_.reconnectDelayMs : policy_.noNetworkReconnectDelayMs)) break;
            continue;
        }

        attempts = 0;
        {
            std::lock_guard<std::mutex> l(mtx_);
            queue_.clear();
            pending_.clear();
            mux_->reset();
            waitKey_ = cfg_.content != ContentMode::AudioOnly;
        }
        connectedAtMs_ = monotonicMs();
        lastPushMs_ = connectedAtMs_;
        if (abr_) { abrBitrate_ = params_.videoBitrateBps; abrFps_ = params_.fps; }
        connected_ = true;
        setState(ConnState::Connected);
        if (hooks_.onNeedKeyframe && cfg_.content != ContentMode::AudioOnly) hooks_.onNeedKeyframe(id_);
        if (abr_ && hooks_.onAbr) hooks_.onAbr(id_, abrBitrate_, abrFps_);

        std::string reason = sendLoop(s);

        connected_ = false;
        abrBitrate_ = 0;
        abrFps_ = 0;
        srt_close(s);
        sock_ = -1;
        if (abr_ && hooks_.onAbr) hooks_.onAbr(id_, 0, 0);  // bỏ ràng buộc ABR của kết nối này
        if (!running_) break;
        {
            std::lock_guard<std::mutex> l(statsMtx_);
            ++stats_.reconnects;
            stats_.uptimeMs = 0;
            bytesBase_ += lastSockBytes_;
            lastSockBytes_ = 0;
        }
        setState(ConnState::Reconnecting, reason);
        if (reason == "idle") {
            // Chờ app đẩy dữ liệu trở lại rồi mới nối
            int64_t idleAt = monotonicMs();
            while (running_ && lastPushMs_ <= idleAt) if (!waitFor(200)) break;
            continue;
        }
        if (!waitFor(network_ ? policy_.reconnectDelayMs : policy_.noNetworkReconnectDelayMs)) break;
    }
}

ConnectionStats SrtConnection::stats() const {
    std::lock_guard<std::mutex> l(statsMtx_);
    ConnectionStats s = stats_;
    s.abrBitrateBps = abrBitrate_;
    s.abrFps = abrFps_;
    return s;
}

} // namespace srtkit
