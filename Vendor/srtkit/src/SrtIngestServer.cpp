#include "srtkit/SrtIngestServer.h"

#include <chrono>
#include <cstring>

#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>

#include <srt/srt.h>

namespace srtkit {

namespace {
std::once_flag gStartup;

std::string peerString(const sockaddr_storage& a) {
    char host[INET6_ADDRSTRLEN] = {0};
    int port = 0;
    if (a.ss_family == AF_INET) {
        auto* v4 = reinterpret_cast<const sockaddr_in*>(&a);
        inet_ntop(AF_INET, &v4->sin_addr, host, sizeof(host));
        port = ntohs(v4->sin_port);
    } else if (a.ss_family == AF_INET6) {
        auto* v6 = reinterpret_cast<const sockaddr_in6*>(&a);
        inet_ntop(AF_INET6, &v6->sin6_addr, host, sizeof(host));
        port = ntohs(v6->sin6_port);
    }
    std::string h = host;
    if (h.rfind("::ffff:", 0) == 0) h = h.substr(7);
    return h + ":" + std::to_string(port);
}
} // namespace

SrtIngestServer::SrtIngestServer(Config cfg, Callbacks cb) : cfg_(std::move(cfg)), cb_(std::move(cb)) {
    std::call_once(gStartup, [] { srt_startup(); });
}

SrtIngestServer::~SrtIngestServer() { stop(); }

std::string SrtIngestServer::keyFromStreamId(const std::string& sid) {
    std::string s = sid;
    if (s.rfind("#!::", 0) == 0) s = s.substr(4);
    if (s.find('=') != std::string::npos) {
        // access-control syntax (with or without the "#!::" prefix): comma separated key=value; resource is "r"
        std::string body = s, r;
        size_t i = 0;
        while (i <= body.size()) {
            size_t j = body.find(',', i);
            std::string kv = body.substr(i, j == std::string::npos ? std::string::npos : j - i);
            size_t eq = kv.find('=');
            if (eq != std::string::npos && kv.substr(0, eq) == "r") r = kv.substr(eq + 1);
            if (j == std::string::npos) break;
            i = j + 1;
        }
        s = r;
    }
    size_t slash = s.find_last_of('/');
    if (slash != std::string::npos) s = s.substr(slash + 1);
    // keep it printable and short
    std::string out;
    for (char c : s) if (c > ' ' && c <= '~' && out.size() < 64) out += c;
    return out;
}

void SrtIngestServer::start() {
    if (running_.exchange(true)) return;
    acceptTh_ = std::thread([this] { acceptLoop(); });
}

void SrtIngestServer::stop() {
    running_ = false;   // join even if the accept loop already gave up (bind failure)
    int l = listener_.exchange(-1);
    if (l >= 0) srt_close(l);
    {
        std::lock_guard<std::mutex> g(mtx_);
        for (auto& c : conns_) if (c->sock >= 0) srt_close(c->sock);
    }
    if (acceptTh_.joinable()) acceptTh_.join();
    reap(true);
}

void SrtIngestServer::reap(bool all) {
    std::vector<std::unique_ptr<Conn>> finished;
    {
        std::lock_guard<std::mutex> g(mtx_);
        for (auto it = conns_.begin(); it != conns_.end();) {
            if (all || (*it)->done.load()) { finished.push_back(std::move(*it)); it = conns_.erase(it); }
            else ++it;
        }
    }
    for (auto& c : finished) if (c->th.joinable()) c->th.join();
}

void SrtIngestServer::acceptLoop() {
    SRTSOCKET s = srt_create_socket();
    SRT_TRANSTYPE tt = SRTT_LIVE;
    srt_setsockflag(s, SRTO_TRANSTYPE, &tt, sizeof(tt));
    int lat = cfg_.latencyMs;
    srt_setsockflag(s, SRTO_LATENCY, &lat, sizeof(lat));
    srt_setsockflag(s, SRTO_RCVLATENCY, &lat, sizeof(lat));
    if (!cfg_.passphrase.empty()) {
        srt_setsockflag(s, SRTO_PASSPHRASE, cfg_.passphrase.data(), static_cast<int>(cfg_.passphrase.size()));
        int kl = cfg_.pbKeyLen;
        srt_setsockflag(s, SRTO_PBKEYLEN, &kl, sizeof(kl));
    }
    // dual-stack [::] first; fall back to IPv4 0.0.0.0 where IPv6 is unavailable
    int only = 0;
    srt_setsockflag(s, SRTO_IPV6ONLY, &only, sizeof(only));
    sockaddr_in6 sa6{};
    sa6.sin6_family = AF_INET6;
    sa6.sin6_addr = in6addr_any;
    sa6.sin6_port = htons(static_cast<uint16_t>(cfg_.port));
    bool bound = srt_bind(s, reinterpret_cast<sockaddr*>(&sa6), sizeof(sa6)) != SRT_ERROR;
    if (!bound) {
        srt_close(s);
        s = srt_create_socket();
        srt_setsockflag(s, SRTO_TRANSTYPE, &tt, sizeof(tt));
        srt_setsockflag(s, SRTO_LATENCY, &lat, sizeof(lat));
        srt_setsockflag(s, SRTO_RCVLATENCY, &lat, sizeof(lat));
        if (!cfg_.passphrase.empty()) {
            srt_setsockflag(s, SRTO_PASSPHRASE, cfg_.passphrase.data(), static_cast<int>(cfg_.passphrase.size()));
            int kl = cfg_.pbKeyLen;
            srt_setsockflag(s, SRTO_PBKEYLEN, &kl, sizeof(kl));
        }
        sockaddr_in sa4{};
        sa4.sin_family = AF_INET;
        sa4.sin_addr.s_addr = htonl(INADDR_ANY);
        sa4.sin_port = htons(static_cast<uint16_t>(cfg_.port));
        bound = srt_bind(s, reinterpret_cast<sockaddr*>(&sa4), sizeof(sa4)) != SRT_ERROR;
    }
    if (!bound || srt_listen(s, cfg_.maxStreams) == SRT_ERROR) {
        std::string err = srt_getlasterror_str();
        srt_close(s);
        if (cb_.onListening) cb_.onListening(cfg_.port, err.empty() ? "listen failed" : err);
        running_ = false;
        return;
    }
    listener_ = s;
    if (cb_.onListening) cb_.onListening(cfg_.port, "");

    int eid = srt_epoll_create();
    int ev = SRT_EPOLL_IN | SRT_EPOLL_ERR;
    srt_epoll_add_usock(eid, s, &ev);
    while (running_) {
        SRTSOCKET rd[1]; int rn = 1;
        if (srt_epoll_wait(eid, rd, &rn, nullptr, nullptr, 500, nullptr, nullptr, nullptr, nullptr) <= 0) { reap(false); continue; }
        sockaddr_storage peer{}; int pl = sizeof(peer);
        SRTSOCKET acc = srt_accept(s, reinterpret_cast<sockaddr*>(&peer), &pl);
        if (acc == SRT_INVALID_SOCK) continue;
        char sid[600] = {0}; int sidLen = sizeof(sid) - 1;
        srt_getsockflag(acc, SRTO_STREAMID, sid, &sidLen);
        std::string key = keyFromStreamId(std::string(sid, sidLen > 0 ? static_cast<size_t>(sidLen) : 0));
        std::string who = peerString(peer);
        if (key.empty()) key = "srt-" + who;
        int rcvTimeo = 1000;
        srt_setsockflag(acc, SRTO_RCVTIMEO, &rcvTimeo, sizeof(rcvTimeo));
        auto c = std::make_unique<Conn>();
        c->sock = acc; c->key = key;
        Conn* raw = c.get();
        {
            std::lock_guard<std::mutex> g(mtx_);
            // same key reconnecting (camera restarted): drop the stale session
            for (auto& o : conns_) if (o->key == key && !o->done && o->sock >= 0) { srt_close(o->sock); o->sock = -1; }
            if (static_cast<int>(conns_.size()) >= cfg_.maxStreams) { srt_close(acc); continue; }
            conns_.push_back(std::move(c));
        }
        if (cb_.onStream) cb_.onStream(key, true, who);
        raw->th = std::thread([this, raw] { serve(raw); });
        reap(false);
    }
    srt_epoll_release(eid);
}

void SrtIngestServer::serve(Conn* c) {
    const std::string key = c->key;
    TsDemuxer* self = nullptr;
    TsDemuxer demux(
        [this, &key](const DemuxedAudioFrame& f) { if (cb_.onAudio) cb_.onAudio(key, f); },
        [this, &key, &self](const uint8_t* b, size_t n, int64_t pts) {
            if (cb_.onVideo) cb_.onVideo(key, b, n, pts, self && self->videoIsHevc());
        });
    self = &demux;
    demux.setAcceptHevc(true);
    std::vector<char> buf(1500);
    while (running_) {
        int n = srt_recvmsg(c->sock, buf.data(), static_cast<int>(buf.size()));
        if (n == SRT_ERROR) {
            int e = srt_getlasterror(nullptr);
            if (e == SRT_EASYNCRCV || e == SRT_ETIMEOUT) continue;
            break;
        }
        demux.feed(reinterpret_cast<const uint8_t*>(buf.data()), static_cast<size_t>(n));
    }
    bool replaced = false;
    {
        std::lock_guard<std::mutex> g(mtx_);
        if (c->sock >= 0) { srt_close(c->sock); c->sock = -1; }
        // a newer session with the same key already took over: don't report it offline
        for (auto& o : conns_) if (o.get() != c && o->key == key && !o->done) replaced = true;
    }
    if (cb_.onStream && !replaced) cb_.onStream(key, false, "");
    c->done = true;
}

} // namespace srtkit
