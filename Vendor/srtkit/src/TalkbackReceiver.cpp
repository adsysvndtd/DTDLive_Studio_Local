#include "srtkit/TalkbackReceiver.h"

#include <chrono>
#include <cstring>

#include <netdb.h>
#include <sys/socket.h>

#include <srt/srt.h>

#include "srtkit/SrtConnection.h"  // monotonicMs

namespace srtkit {

namespace {
std::once_flag gInit;
bool resolveAddr(const std::string& host, int port, bool passive, sockaddr_storage& out, socklen_t& len) {
    addrinfo hints{}, *res = nullptr;
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_DGRAM;
    if (passive) hints.ai_flags = AI_PASSIVE;
    std::string p = std::to_string(port);
    if (getaddrinfo(host.empty() ? nullptr : host.c_str(), p.c_str(), &hints, &res) != 0 || !res) return false;
    addrinfo* pick = res;
    if (passive && host.empty())
        for (addrinfo* a = res; a; a = a->ai_next) if (a->ai_family == AF_INET) { pick = a; break; }
    std::memcpy(&out, pick->ai_addr, pick->ai_addrlen);
    len = static_cast<socklen_t>(pick->ai_addrlen);
    freeaddrinfo(res);
    return true;
}
} // namespace

TalkbackReceiver::TalkbackReceiver(const Config& cfg, Callbacks cb) : cfg_(cfg), cb_(std::move(cb)) {
    std::call_once(gInit, [] { srt_startup(); });
}

TalkbackReceiver::~TalkbackReceiver() { stop(); }

void TalkbackReceiver::setState(ConnState s, const std::string& info) {
    if (state_.exchange(s) != s && cb_.onState) cb_.onState(s, info);
}

void TalkbackReceiver::start() {
    if (running_.exchange(true)) return;
    netTh_ = std::thread([this] { netLoop(); });
    if (cb_.onAudio) playTh_ = std::thread([this] { playLoop(); });
}

void TalkbackReceiver::stop() {
    if (!running_.exchange(false)) return;
    int s = sock_.load();
    if (s >= 0) srt_close(s);
    qCv_.notify_all();
    if (netTh_.joinable()) netTh_.join();
    if (playTh_.joinable()) playTh_.join();
    setState(ConnState::Idle, "stopped");
}

int TalkbackReceiver::open(std::string& err) {
    const SrtOptions& o = cfg_.srt;
    SRTSOCKET s = srt_create_socket();
    sock_ = s;
    SRT_TRANSTYPE tt = SRTT_LIVE;
    srt_setsockflag(s, SRTO_TRANSTYPE, &tt, sizeof(tt));
    int lat = o.latencyMs;
    srt_setsockflag(s, SRTO_LATENCY, &lat, sizeof(lat));
    srt_setsockflag(s, SRTO_RCVLATENCY, &lat, sizeof(lat));   // the larger of both ends is used
    int ct = o.connectTimeoutMs;
    srt_setsockflag(s, SRTO_CONNTIMEO, &ct, sizeof(ct));
    if (!o.passphrase.empty()) {
        if (srt_setsockflag(s, SRTO_PASSPHRASE, o.passphrase.data(), static_cast<int>(o.passphrase.size())) == SRT_ERROR) {
            err = "SRT encryption unavailable"; srt_close(s); sock_ = -1; return -1;
        }
        int kl = o.pbKeyLen;
        srt_setsockflag(s, SRTO_PBKEYLEN, &kl, sizeof(kl));
    }
    if (!o.streamId.empty()) srt_setsockflag(s, SRTO_STREAMID, o.streamId.data(), static_cast<int>(o.streamId.size()));
    int rcvTimeo = 1000;
    srt_setsockflag(s, SRTO_RCVTIMEO, &rcvTimeo, sizeof(rcvTimeo));

    sockaddr_storage sa{};
    socklen_t saLen = 0;
    if (o.mode == SrtMode::Listener) {
        if (o.host == "::") {
            int only = 0;
            srt_setsockflag(s, SRTO_IPV6ONLY, &only, sizeof(only));
        }
        if (!resolveAddr(o.host, o.port, true, sa, saLen) ||
            srt_bind(s, reinterpret_cast<sockaddr*>(&sa), saLen) == SRT_ERROR || srt_listen(s, 1) == SRT_ERROR) {
            err = std::string("listen: ") + srt_getlasterror_str();
            srt_close(s); sock_ = -1; return -1;
        }
        if (cb_.onListening) {
            int addrLen = sizeof(sa);
            if (srt_getsockname(s, reinterpret_cast<sockaddr*>(&sa), &addrLen) == SRT_ERROR) {
                err = "getsockname"; srt_close(s); sock_ = -1; return -1;
            }
            cfg_.srt.port = sa.ss_family == AF_INET6
                ? ntohs(reinterpret_cast<sockaddr_in6*>(&sa)->sin6_port)
                : ntohs(reinterpret_cast<sockaddr_in*>(&sa)->sin_port);
            cb_.onListening(cfg_.srt.port);
        }
        setState(ConnState::Listening);
        int eid = srt_epoll_create();
        int ev = SRT_EPOLL_IN | SRT_EPOLL_ERR;
        srt_epoll_add_usock(eid, s, &ev);
        SRTSOCKET acc = SRT_INVALID_SOCK;
        while (running_) {
            SRTSOCKET rd[1]; int rn = 1;
            if (srt_epoll_wait(eid, rd, &rn, nullptr, nullptr, 500, nullptr, nullptr, nullptr, nullptr) > 0) {
                sockaddr_storage peer{}; int pl = sizeof(peer);
                acc = srt_accept(s, reinterpret_cast<sockaddr*>(&peer), &pl);
                break;
            }
        }
        srt_epoll_release(eid);
        srt_close(s);
        sock_ = acc == SRT_INVALID_SOCK ? -1 : acc;
        if (acc == SRT_INVALID_SOCK) err = "accept failed";
        else srt_setsockflag(acc, SRTO_RCVTIMEO, &rcvTimeo, sizeof(rcvTimeo));
        return acc == SRT_INVALID_SOCK ? -1 : acc;
    }

    setState(ConnState::Connecting);
    if (!resolveAddr(o.host, o.port, false, sa, saLen)) { err = "resolve"; srt_close(s); sock_ = -1; return -1; }
    if (o.mode == SrtMode::Rendezvous) {
        bool r = true;
        srt_setsockflag(s, SRTO_RENDEZVOUS, &r, sizeof(r));
        sockaddr_storage local{}; socklen_t ll = 0;
        resolveAddr(sa.ss_family == AF_INET6 ? "::" : "0.0.0.0", o.localPort ? o.localPort : o.port, true, local, ll);
        if (srt_bind(s, reinterpret_cast<sockaddr*>(&local), ll) == SRT_ERROR) {
            err = std::string("bind: ") + srt_getlasterror_str(); srt_close(s); sock_ = -1; return -1;
        }
    }
    if (srt_connect(s, reinterpret_cast<sockaddr*>(&sa), saLen) == SRT_ERROR) {
        err = std::string("connect: ") + srt_getlasterror_str();
        srt_close(s); sock_ = -1; return -1;
    }
    return s;
}

void TalkbackReceiver::netLoop() {
    TsDemuxer::AudioSink audio;
    if (cb_.onAudio) audio = [this](const DemuxedAudioFrame& f) {
        ++framesIn_;
        std::lock_guard<std::mutex> l(qMtx_);
        q_.push_back(f);
        if (q_.size() > 2000) q_.pop_front();  // bảo vệ bộ nhớ
        qCv_.notify_one();
    };
    TsDemuxer demux(std::move(audio), cb_.onVideo);
    std::vector<char> buf(1500);
    while (running_) {
        std::string err;
        int s = open(err);
        if (s < 0) {
            if (!running_) break;
            setState(ConnState::Reconnecting, err);
            for (int w = 0; w < cfg_.reconnectDelayMs && running_; w += 100) std::this_thread::sleep_for(std::chrono::milliseconds(100));
            continue;
        }
        setState(ConnState::Connected);
        demux.reset();
        {
            std::lock_guard<std::mutex> l(qMtx_);
            q_.clear();
            clockSet_ = false;
        }
        while (running_) {
            int n = srt_recvmsg(s, buf.data(), static_cast<int>(buf.size()));
            if (n == SRT_ERROR) {
                int e = srt_getlasterror(nullptr);
                if (e == SRT_EASYNCRCV || e == SRT_ETIMEOUT) continue;  // timeout 1 s, kiểm tra running_
                break;
            }
            demux.feed(reinterpret_cast<const uint8_t*>(buf.data()), static_cast<size_t>(n));
            ccErrors_ = demux.ccErrors(); videoDropped_ = demux.videoDropped();
        }
        srt_close(s);
        sock_ = -1;
        if (!running_) break;
        setState(ConnState::Reconnecting, srt_getlasterror_str());
        for (int w = 0; w < cfg_.reconnectDelayMs && running_; w += 100) std::this_thread::sleep_for(std::chrono::milliseconds(100));
    }
}

void TalkbackReceiver::playLoop() {
    // Đồng hồ phát: frame đầu tiên được phát sau bufferMs; các frame sau theo khoảng cách PTS.
    while (running_) {
        DemuxedAudioFrame f;
        {
            std::unique_lock<std::mutex> l(qMtx_);
            qCv_.wait_for(l, std::chrono::milliseconds(50), [&] { return !q_.empty() || !running_; });
            if (!running_) break;
            if (q_.empty()) continue;
            int64_t now = monotonicMs();
            if (!clockSet_) {
                clockBasePts_ = q_.front().ptsUs;
                clockBaseMs_ = now + cfg_.bufferMs;
                clockSet_ = true;
            }
            int64_t due = clockBaseMs_ + (q_.front().ptsUs - clockBasePts_) / 1000;
            // PTS nhảy (nguồn khởi động lại) -> đặt lại đồng hồ
            if (due - now > cfg_.bufferMs + 5000 || due - now < -5000) { clockSet_ = false; continue; }
            if (due > now) {
                qCv_.wait_for(l, std::chrono::milliseconds(due - now));
                if (!running_) break;
                continue;
            }
            f = std::move(q_.front());
            q_.pop_front();
            if (now - due > 200) { ++framesLate_; continue; }  // quá trễ -> bỏ
        }
        if (cb_.onAudio) cb_.onAudio(f);
    }
}

} // namespace srtkit

namespace srtkit {
TalkbackReceiver::LinkStats TalkbackReceiver::linkStats() {
    LinkStats st;
    int s = sock_;
    st.ccErrors = ccErrors_; st.videoDropped = videoDropped_;
    if (s < 0 || state_ != ConnState::Connected) return st;
    SRT_TRACEBSTATS perf{};
    if (srt_bstats(s, &perf, 0) != 0) return st;
    st.connected = true;
    st.pktRecv = perf.pktRecvTotal;
    st.pktLoss = perf.pktRcvLossTotal;
    st.pktDrop = perf.pktRcvDropTotal;
    st.pktRetrans = perf.pktRcvRetrans;
    st.rttMs = perf.msRTT;
    st.mbpsRecv = perf.mbpsRecvRate;
    st.mbpsBandwidth = perf.mbpsBandwidth;
    st.msRcvBuf = perf.msRcvBuf;
    int lat = 0, len = sizeof(lat);
    if (srt_getsockflag(s, SRTO_RCVLATENCY, &lat, &len) == 0) st.latencyMs = lat;
    return st;
}
} // namespace srtkit
