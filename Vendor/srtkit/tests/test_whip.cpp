// Kiểm thử WhipClient: POST offer tới máy chủ WHIP (HTTP thường), nhận answer, đẩy H.264 + Opus từ file.
// Dùng: test_whip http://127.0.0.1:8089/whip video.bin audio.bin sps.bin pps.bin
#include "srtkit/WhipClient.h"

#include <arpa/inet.h>
#include <netdb.h>
#include <sys/socket.h>
#include <unistd.h>

#include <chrono>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <string>
#include <thread>
#include <vector>

using namespace srtkit;

static std::vector<uint8_t> readAll(const char* p) {
    std::ifstream f(p, std::ios::binary);
    return std::vector<uint8_t>((std::istreambuf_iterator<char>(f)), {});
}

static std::string httpPost(const std::string& host, int port, const std::string& path, const std::string& body) {
    addrinfo h{}, *r;
    h.ai_socktype = SOCK_STREAM;
    getaddrinfo(host.c_str(), std::to_string(port).c_str(), &h, &r);
    int fd = socket(r->ai_family, SOCK_STREAM, 0);
    connect(fd, r->ai_addr, r->ai_addrlen);
    freeaddrinfo(r);
    std::string req = "POST " + path + " HTTP/1.1\r\nHost: " + host + "\r\nContent-Type: application/sdp\r\nContent-Length: " +
                      std::to_string(body.size()) + "\r\nConnection: close\r\n\r\n" + body;
    send(fd, req.data(), req.size(), 0);
    std::string resp;
    char buf[4096];
    ssize_t n;
    while ((n = recv(fd, buf, sizeof buf, 0)) > 0) resp.append(buf, n);
    close(fd);
    size_t p = resp.find("\r\n\r\n");
    return p == std::string::npos ? "" : resp.substr(p + 4);
}

int main(int argc, char** argv) {
    if (argc < 6) { fprintf(stderr, "usage\n"); return 2; }
    std::string url = argv[1];   // http://host:port/path
    std::string rest = url.substr(7);
    std::string hp = rest.substr(0, rest.find('/')), path = rest.substr(rest.find('/'));
    std::string host = hp.substr(0, hp.find(':'));
    int port = atoi(hp.substr(hp.find(':') + 1).c_str());
    auto video = readAll(argv[2]), audio = readAll(argv[3]);
    std::vector<std::vector<uint8_t>> sps{readAll(argv[4])}, pps{readAll(argv[5])};

    // kiểm CRC32 chuẩn
    if (whip_detail::crc32((const uint8_t*)"123456789", 9) != 0xCBF43926) { fprintf(stderr, "crc32 sai\n"); return 1; }

    WhipClient::Options o;
    char pl[8];
    snprintf(pl, sizeof pl, "%02x%02x%02x", sps[0][1], sps[0][2], sps[0][3]);
    o.h264ProfileLevelId = getenv("WHIP_PLID") ? getenv("WHIP_PLID") : pl;
    WhipClient c(o);
    std::atomic<int> keyreq{0};
    std::atomic<bool> connected{false};
    c.onState = [&](WhipClient::State s, const std::string& i) {
        printf("state %d %s\n", (int)s, i.c_str());
        fflush(stdout);
        if (s == WhipClient::State::Connected) connected = true;
    };
    c.onKeyframeRequest = [&] { keyreq++; };
    std::string offer = c.createOffer();
    printf("--- offer ---\n%s\n", offer.c_str());
    std::string ans = httpPost(host, port, path, offer);
    std::string err = c.setAnswer(ans);
    if (!err.empty()) { fprintf(stderr, "answer: %s\n", err.c_str()); return 1; }
    c.start();
    for (int i = 0; i < 200 && !connected; i++) std::this_thread::sleep_for(std::chrono::milliseconds(50));
    if (!connected) { fprintf(stderr, "không kết nối được\n"); return 1; }

    // phát theo thời gian thực: trộn hình/tiếng theo PTS
    size_t vi = 0, ai = 0;
    auto t0 = std::chrono::steady_clock::now();
    int64_t base = 1'000'000'000;
    while (vi < video.size() || ai < audio.size()) {
        int64_t vp = INT64_MAX, ap = INT64_MAX;
        uint32_t vl = 0, al = 0;
        uint8_t key = 0;
        if (vi + 13 <= video.size()) { memcpy(&vl, &video[vi], 4); key = video[vi + 4]; memcpy(&vp, &video[vi + 5], 8); }
        if (ai + 12 <= audio.size()) { memcpy(&al, &audio[ai], 4); memcpy(&ap, &audio[ai + 4], 8); }
        int64_t next = std::min(vp, ap);
        if (next == INT64_MAX) break;
        auto due = t0 + std::chrono::microseconds(next);
        std::this_thread::sleep_until(due);
        if (vp <= ap) { c.sendVideo(&video[vi + 13], vl, base + vp, key, sps, pps); vi += 13 + vl; }
        else { c.sendOpus(&audio[ai + 12], al, base + ap); ai += 12 + al; }
    }
    auto s = c.stats();
    printf("sent %llu bytes %llu packets, nack %llu rtx %llu pli %llu rtt %.1f\n", (unsigned long long)s.bytesSent,
           (unsigned long long)s.packetsSent, (unsigned long long)s.nacksReceived, (unsigned long long)s.retransmitted,
           (unsigned long long)s.keyframeRequests, s.rttMs);
    std::this_thread::sleep_for(std::chrono::milliseconds(500));
    c.stop();
    printf("WHIP TEST DONE\n");
    return 0;
}
