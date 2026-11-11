#include "srtkit/Timecode.h"

#include <chrono>
#include <cstring>

#include <arpa/inet.h>
#include <netdb.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

namespace srtkit {

const uint8_t kSrtKitTimecodeUuid[16] = {0x53, 0x52, 0x54, 0x4B, 0x2D, 0x54, 0x43, 0x01,   // "SRTK-TC" v1
                                         0x9a, 0x3c, 0x4e, 0x21, 0xb7, 0x55, 0x0f, 0xd2};

namespace {
constexpr int64_t kNtpUnixDeltaSec = 2208988800LL;  // 1900 -> 1970

int64_t systemUnixUs() {
    return std::chrono::duration_cast<std::chrono::microseconds>(
               std::chrono::system_clock::now().time_since_epoch()).count();
}

void unixUsToNtp(int64_t us, uint8_t* out8) {
    uint64_t sec = static_cast<uint64_t>(us / 1000000 + kNtpUnixDeltaSec);
    uint64_t frac = (static_cast<uint64_t>(us % 1000000) << 32) / 1000000;
    for (int i = 0; i < 4; ++i) out8[i] = static_cast<uint8_t>(sec >> (24 - 8 * i));
    for (int i = 0; i < 4; ++i) out8[4 + i] = static_cast<uint8_t>(frac >> (24 - 8 * i));
}

int64_t ntpToUnixUs(const uint8_t* in8) {
    uint64_t sec = 0, frac = 0;
    for (int i = 0; i < 4; ++i) sec = (sec << 8) | in8[i];
    for (int i = 0; i < 4; ++i) frac = (frac << 8) | in8[4 + i];
    return (static_cast<int64_t>(sec) - kNtpUnixDeltaSec) * 1000000 + static_cast<int64_t>((frac * 1000000) >> 32);
}

// Thêm byte 0x03 chống giả start code
void appendEscaped(std::vector<uint8_t>& out, const uint8_t* rbsp, size_t len) {
    int zeros = 0;
    for (size_t i = 0; i < len; ++i) {
        if (zeros >= 2 && rbsp[i] <= 0x03) { out.push_back(0x03); zeros = 0; }
        out.push_back(rbsp[i]);
        zeros = rbsp[i] == 0 ? zeros + 1 : 0;
    }
}

std::vector<uint8_t> unescape(const uint8_t* p, size_t len) {
    std::vector<uint8_t> out;
    int zeros = 0;
    for (size_t i = 0; i < len; ++i) {
        if (zeros >= 2 && p[i] == 0x03) { zeros = 0; continue; }
        out.push_back(p[i]);
        zeros = p[i] == 0 ? zeros + 1 : 0;
    }
    return out;
}
} // namespace

// ---------------------------------------------------------------------------
NtpClock::~NtpClock() { stop(); }

bool NtpClock::query(const std::string& host, int timeoutMs, int64_t& offsetUs, int64_t& rttUs) {
    addrinfo hints{}, *res = nullptr;
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_DGRAM;
    if (getaddrinfo(host.c_str(), "123", &hints, &res) != 0 || !res) return false;
    int fd = socket(res->ai_family, SOCK_DGRAM, 0);
    if (fd < 0) { freeaddrinfo(res); return false; }
    timeval tv{timeoutMs / 1000, (timeoutMs % 1000) * 1000};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

    uint8_t pkt[48] = {};
    pkt[0] = 0x23;  // LI=0, VN=4, Mode=3 (client)
    int64_t t1 = systemUnixUs();
    unixUsToNtp(t1, pkt + 40);  // transmit timestamp
    bool ok = false;
    if (sendto(fd, pkt, sizeof(pkt), 0, res->ai_addr, res->ai_addrlen) == sizeof(pkt)) {
        uint8_t r[48];
        ssize_t n = recv(fd, r, sizeof(r), 0);
        int64_t t4 = systemUnixUs();
        if (n == 48 && (r[0] & 0x07) == 4 && r[1] != 0) {
            int64_t t2 = ntpToUnixUs(r + 32);  // receive
            int64_t t3 = ntpToUnixUs(r + 40);  // transmit
            offsetUs = ((t2 - t1) + (t3 - t4)) / 2;
            rttUs = (t4 - t1) - (t3 - t2);
            ok = true;
        }
    }
    close(fd);
    freeaddrinfo(res);
    return ok;
}

void NtpClock::start(const std::string& host, int refreshSec) {
    stop();
    running_ = true;
    th_ = std::thread([this, host, refreshSec] {
        while (running_) {
            int64_t off = 0, rtt = 0;
            bool ok = false;
            for (int i = 0; i < 3 && running_ && !ok; ++i) ok = query(host, 1500, off, rtt);
            if (ok) { offsetUs_ = off; synced_ = true; }
            int waitMs = ok ? refreshSec * 1000 : 10000;  // lỗi thì thử lại sau 10 s
            for (int w = 0; w < waitMs && running_; w += 100) std::this_thread::sleep_for(std::chrono::milliseconds(100));
        }
    });
}

void NtpClock::stop() {
    running_ = false;
    if (th_.joinable()) th_.join();
}

int64_t NtpClock::nowUnixUs() const { return systemUnixUs() + offsetUs_.load(); }

// ---------------------------------------------------------------------------
std::vector<uint8_t> buildTimecodeSei(VideoCodec codec, int64_t unixUs) {
    std::vector<uint8_t> rbsp;
    rbsp.push_back(5);        // payloadType = user_data_unregistered
    rbsp.push_back(16 + 8);   // payloadSize
    rbsp.insert(rbsp.end(), kSrtKitTimecodeUuid, kSrtKitTimecodeUuid + 16);
    uint8_t ntp[8];
    unixUsToNtp(unixUs, ntp);
    rbsp.insert(rbsp.end(), ntp, ntp + 8);
    rbsp.push_back(0x80);     // rbsp_trailing_bits

    std::vector<uint8_t> nal;
    if (codec == VideoCodec::HEVC) { nal.push_back(39 << 1); nal.push_back(0x01); }  // PREFIX_SEI, tid=1
    else nal.push_back(0x06);
    appendEscaped(nal, rbsp.data(), rbsp.size());
    return nal;
}

bool parseTimecodeSei(VideoCodec codec, const uint8_t* nal, size_t len, int64_t& unixUs) {
    size_t hdr = codec == VideoCodec::HEVC ? 2 : 1;
    if (len < hdr + 2 + 24) return false;
    auto r = unescape(nal + hdr, len - hdr);
    if (r.size() < 26 || r[0] != 5 || r[1] != 24) return false;
    if (std::memcmp(r.data() + 2, kSrtKitTimecodeUuid, 16) != 0) return false;
    unixUs = ntpToUnixUs(r.data() + 18);
    return true;
}

} // namespace srtkit
