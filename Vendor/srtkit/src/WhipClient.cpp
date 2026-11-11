// SRTKit – WHIP client: ICE-controlling (STUN), DTLS-SRTP (mbedTLS), SRTP AES_CM_128_HMAC_SHA1_80,
// RTP H.264 (STAP-A / FU-A) + Opus, RTCP SR/SDES, xử lý NACK / PLI / FIR / RR.
#include "srtkit/WhipClient.h"

#include <mbedtls/aes.h>
#include <mbedtls/ctr_drbg.h>
#include <mbedtls/ecp.h>
#include <mbedtls/entropy.h>
#include <mbedtls/error.h>
#include <mbedtls/md.h>
#include <mbedtls/pk.h>
#include <mbedtls/ssl.h>
#include <mbedtls/timing.h>
#include <mbedtls/x509_crt.h>
#include <mbedtls/x509_csr.h>
#include <psa/crypto.h>

#include <arpa/inet.h>
#include <fcntl.h>
#include <netdb.h>
#include <netinet/in.h>
#include <poll.h>
#include <sys/socket.h>
#include <unistd.h>

#include <algorithm>
#include <array>
#include <chrono>
#include <cstring>
#include <deque>
#include <map>
#include <mutex>
#include <sstream>
#include <thread>

#if !defined(MBEDTLS_SSL_DTLS_SRTP)
#error "mbedTLS cần bật MBEDTLS_SSL_DTLS_SRTP (scripts/config.py set MBEDTLS_SSL_DTLS_SRTP)"
#endif

namespace srtkit {

namespace whip_detail {
uint32_t crc32(const uint8_t* p, size_t n) {
    static uint32_t table[256];
    static bool init = false;
    if (!init) {
        for (uint32_t i = 0; i < 256; i++) {
            uint32_t c = i;
            for (int k = 0; k < 8; k++) c = (c & 1) ? 0xEDB88320u ^ (c >> 1) : c >> 1;
            table[i] = c;
        }
        init = true;
    }
    uint32_t c = 0xFFFFFFFFu;
    for (size_t i = 0; i < n; i++) c = table[(c ^ p[i]) & 0xFF] ^ (c >> 8);
    return c ^ 0xFFFFFFFFu;
}
} // namespace whip_detail

namespace {

using Clock = std::chrono::steady_clock;
using Bytes = std::vector<uint8_t>;

inline void put16(Bytes& b, uint16_t v) { b.push_back(v >> 8); b.push_back(v & 0xFF); }
inline void put32(Bytes& b, uint32_t v) { b.push_back(v >> 24); b.push_back((v >> 16) & 0xFF); b.push_back((v >> 8) & 0xFF); b.push_back(v & 0xFF); }
inline uint16_t get16(const uint8_t* p) { return uint16_t(p[0] << 8 | p[1]); }
inline uint32_t get32(const uint8_t* p) { return uint32_t(p[0]) << 24 | uint32_t(p[1]) << 16 | uint32_t(p[2]) << 8 | p[3]; }

std::string hexColon(const uint8_t* p, size_t n) {
    static const char* h = "0123456789ABCDEF";
    std::string s;
    for (size_t i = 0; i < n; i++) {
        if (i) s += ':';
        s += h[p[i] >> 4]; s += h[p[i] & 15];
    }
    return s;
}

std::string lower(std::string s) { for (auto& c : s) c = (char)tolower((unsigned char)c); return s; }
std::string trim(const std::string& s) {
    size_t a = s.find_first_not_of(" \t\r\n"), b = s.find_last_not_of(" \t\r\n");
    return a == std::string::npos ? "" : s.substr(a, b - a + 1);
}

void hmacSha1(const uint8_t* key, size_t klen, const uint8_t* a, size_t alen, const uint8_t* b, size_t blen, uint8_t out[20]) {
    const mbedtls_md_info_t* md = mbedtls_md_info_from_type(MBEDTLS_MD_SHA1);
    mbedtls_md_context_t c;
    mbedtls_md_init(&c);
    mbedtls_md_setup(&c, md, 1);
    mbedtls_md_hmac_starts(&c, key, klen);
    mbedtls_md_hmac_update(&c, a, alen);
    if (blen) mbedtls_md_hmac_update(&c, b, blen);
    mbedtls_md_hmac_finish(&c, out);
    mbedtls_md_free(&c);
}

// ---------------------------------------------------------------------------
// SRTP / SRTCP – AES_CM_128_HMAC_SHA1_80 (RFC 3711)
// ---------------------------------------------------------------------------
struct SrtpKeys {
    mbedtls_aes_context rtpAes, rtcpAes;
    uint8_t rtpAuth[20], rtpSalt[14], rtcpAuth[20], rtcpSalt[14];
    bool ready = false;

    SrtpKeys() { mbedtls_aes_init(&rtpAes); mbedtls_aes_init(&rtcpAes); }
    ~SrtpKeys() { mbedtls_aes_free(&rtpAes); mbedtls_aes_free(&rtcpAes); }

    static void derive(const uint8_t key[16], const uint8_t salt[14], uint8_t label, uint8_t* out, size_t n) {
        mbedtls_aes_context a;
        mbedtls_aes_init(&a);
        mbedtls_aes_setkey_enc(&a, key, 128);
        uint8_t iv[16] = {0};
        memcpy(iv, salt, 14);
        iv[7] ^= label;
        uint8_t block[16];
        size_t off = 0;
        std::vector<uint8_t> zeros(n, 0);
        mbedtls_aes_crypt_ctr(&a, n, &off, iv, block, zeros.data(), out);
        mbedtls_aes_free(&a);
    }

    void init(const uint8_t key[16], const uint8_t salt[14]) {
        uint8_t k[16];
        derive(key, salt, 0, k, 16); mbedtls_aes_setkey_enc(&rtpAes, k, 128);
        derive(key, salt, 1, rtpAuth, 20);
        derive(key, salt, 2, rtpSalt, 14);
        derive(key, salt, 3, k, 16); mbedtls_aes_setkey_enc(&rtcpAes, k, 128);
        derive(key, salt, 4, rtcpAuth, 20);
        derive(key, salt, 5, rtcpSalt, 14);
        ready = true;
    }

    static void ctr(mbedtls_aes_context* aes, const uint8_t salt[14], uint32_t ssrc, uint64_t index, uint8_t* p, size_t n) {
        uint8_t iv[16] = {0};
        memcpy(iv, salt, 14);
        iv[4] ^= ssrc >> 24; iv[5] ^= (ssrc >> 16) & 0xFF; iv[6] ^= (ssrc >> 8) & 0xFF; iv[7] ^= ssrc & 0xFF;
        for (int i = 0; i < 6; i++) iv[8 + i] ^= (index >> (40 - 8 * i)) & 0xFF;
        uint8_t block[16];
        size_t off = 0;
        mbedtls_aes_crypt_ctr(aes, n, &off, iv, block, p, p);
    }

    // rtp: gói RTP rõ (header 12 byte, không CSRC/extension) → thêm tag 10 byte
    void protectRtp(Bytes& pkt, uint32_t roc) {
        uint16_t seq = get16(&pkt[2]);
        uint32_t ssrc = get32(&pkt[8]);
        uint64_t index = (uint64_t(roc) << 16) | seq;
        ctr(&rtpAes, rtpSalt, ssrc, index, pkt.data() + 12, pkt.size() - 12);
        uint8_t r[4] = {uint8_t(roc >> 24), uint8_t(roc >> 16), uint8_t(roc >> 8), uint8_t(roc)};
        uint8_t tag[20];
        hmacSha1(rtpAuth, 20, pkt.data(), pkt.size(), r, 4, tag);
        pkt.insert(pkt.end(), tag, tag + 10);
    }

    void protectRtcp(Bytes& pkt, uint32_t index) {
        uint32_t ssrc = get32(&pkt[4]);
        ctr(&rtcpAes, rtcpSalt, ssrc, index, pkt.data() + 8, pkt.size() - 8);
        put32(pkt, 0x80000000u | index);
        uint8_t tag[20];
        hmacSha1(rtcpAuth, 20, pkt.data(), pkt.size(), nullptr, 0, tag);
        pkt.insert(pkt.end(), tag, tag + 10);
    }

    bool unprotectRtcp(Bytes& pkt) {
        if (pkt.size() < 8 + 4 + 10) return false;
        size_t n = pkt.size();
        uint8_t tag[20];
        hmacSha1(rtcpAuth, 20, pkt.data(), n - 10, nullptr, 0, tag);
        if (memcmp(tag, &pkt[n - 10], 10) != 0) return false;
        uint32_t ei = get32(&pkt[n - 14]);
        pkt.resize(n - 14);
        if (ei & 0x80000000u) ctr(&rtcpAes, rtcpSalt, get32(&pkt[4]), ei & 0x7FFFFFFF, pkt.data() + 8, pkt.size() - 8);
        return true;
    }
};

// ---------------------------------------------------------------------------
// STUN
// ---------------------------------------------------------------------------
constexpr uint32_t kMagic = 0x2112A442;

Bytes stunBuild(uint16_t type, const uint8_t txid[12], const std::vector<std::pair<uint16_t, Bytes>>& attrs, const std::string& integrityKey) {
    Bytes m;
    put16(m, type); put16(m, 0); put32(m, kMagic);
    m.insert(m.end(), txid, txid + 12);
    for (auto& a : attrs) {
        put16(m, a.first); put16(m, (uint16_t)a.second.size());
        m.insert(m.end(), a.second.begin(), a.second.end());
        while (m.size() % 4) m.push_back(0);
    }
    if (!integrityKey.empty()) {
        uint16_t l = uint16_t(m.size() - 20 + 24);
        m[2] = l >> 8; m[3] = l & 0xFF;
        uint8_t h[20];
        hmacSha1((const uint8_t*)integrityKey.data(), integrityKey.size(), m.data(), m.size(), nullptr, 0, h);
        put16(m, 0x0008); put16(m, 20);
        m.insert(m.end(), h, h + 20);
    }
    uint16_t l = uint16_t(m.size() - 20 + 8);
    m[2] = l >> 8; m[3] = l & 0xFF;
    uint32_t crc = whip_detail::crc32(m.data(), m.size()) ^ 0x5354554e;
    put16(m, 0x8028); put16(m, 4); put32(m, crc);
    return m;
}

Bytes xorMapped(const sockaddr_storage& a) {
    Bytes v;
    if (a.ss_family == AF_INET) {
        auto* s = (const sockaddr_in*)&a;
        v = {0, 0x01};
        put16(v, ntohs(s->sin_port) ^ (kMagic >> 16));
        put32(v, ntohl(s->sin_addr.s_addr) ^ kMagic);
    } else {
        auto* s = (const sockaddr_in6*)&a;
        v = {0, 0x02};
        put16(v, ntohs(s->sin6_port) ^ (kMagic >> 16));
        uint8_t mk[4] = {0x21, 0x12, 0xA4, 0x42};
        for (int i = 0; i < 16; i++) v.push_back(s->sin6_addr.s6_addr[i] ^ (i < 4 ? mk[i] : 0));  // txid phần sau gán khi gọi
    }
    return v;
}

bool sameAddr(const sockaddr_storage& a, const sockaddr_storage& b) {
    if (a.ss_family != b.ss_family) return false;
    if (a.ss_family == AF_INET) {
        auto *x = (const sockaddr_in*)&a, *y = (const sockaddr_in*)&b;
        return x->sin_port == y->sin_port && x->sin_addr.s_addr == y->sin_addr.s_addr;
    }
    auto *x = (const sockaddr_in6*)&a, *y = (const sockaddr_in6*)&b;
    return x->sin6_port == y->sin6_port && memcmp(&x->sin6_addr, &y->sin6_addr, 16) == 0;
}

socklen_t addrLen(const sockaddr_storage& a) { return a.ss_family == AF_INET ? sizeof(sockaddr_in) : sizeof(sockaddr_in6); }

struct Candidate {
    sockaddr_storage addr{};
    uint32_t priority = 0;
    std::string type;
};

} // namespace

// ---------------------------------------------------------------------------
struct WhipClient::Impl {
    Options opt;
    std::atomic<State> state{State::Idle};
    WhipClient* owner = nullptr;

    // crypto
    mbedtls_entropy_context entropy;
    mbedtls_ctr_drbg_context drbg;
    mbedtls_pk_context key;
    mbedtls_x509_crt cert;
    std::string localFingerprint;
    std::string localUfrag, localPwd;
    uint64_t tieBreaker = 0;

    // answer
    std::string remoteUfrag, remotePwd, remoteFpAlg, remoteFp;
    bool dtlsClient = true;
    std::vector<Candidate> cands;
    int opusPt = 111, h264Pt = 102;
    uint32_t audioSsrc = 0, videoSsrc = 0;

    // mạng
    int fd = -1;
    sockaddr_storage selected{};
    bool haveSelected = false;
    std::map<std::string, size_t> pendingTx;   // txid → chỉ số ứng viên
    Clock::time_point lastStunResp{};

    // DTLS
    mbedtls_ssl_config conf;
    mbedtls_ssl_context ssl;
    mbedtls_timing_delay_context timer;
    std::deque<Bytes> dtlsIn;
    uint8_t masterSecret[48];
    uint8_t randBytes[64];
    mbedtls_tls_prf_types prfType = MBEDTLS_SSL_TLS_PRF_NONE;
    bool keysExported = false;

    // SRTP
    std::mutex tx;
    SrtpKeys out, in;
    uint16_t vSeq = 0, aSeq = 0;
    uint32_t vRoc = 0, aRoc = 0;
    uint32_t srtcpIndex = 0;
    uint32_t tsOffsetV = 0, tsOffsetA = 0;
    int64_t baseUs = INT64_MIN;
    struct Last { uint32_t rtp = 0; Clock::time_point wall{}; uint32_t packets = 0, octets = 0; bool any = false; };
    Last lastV, lastA;
    std::array<Bytes, 1024> history;           // gói video đã mã hoá, theo seq % 1024
    std::array<uint16_t, 1024> historySeq{};
    std::map<uint32_t, Clock::time_point> srSent;  // mid32 NTP → thời điểm gửi
    Clock::time_point lastPli{};

    WhipStats st;
    mutable std::mutex stMtx;

    std::thread worker;
    std::atomic<bool> running{false};
    std::string failReason;

    Impl() {
        mbedtls_entropy_init(&entropy);
        mbedtls_ctr_drbg_init(&drbg);
        mbedtls_pk_init(&key);
        mbedtls_x509_crt_init(&cert);
        mbedtls_ssl_config_init(&conf);
        mbedtls_ssl_init(&ssl);
        psa_crypto_init();
        const char* pers = "srtkit-whip";
        mbedtls_ctr_drbg_seed(&drbg, mbedtls_entropy_func, &entropy, (const uint8_t*)pers, strlen(pers));
    }

    ~Impl() {
        mbedtls_ssl_free(&ssl);
        mbedtls_ssl_config_free(&conf);
        mbedtls_x509_crt_free(&cert);
        mbedtls_pk_free(&key);
        mbedtls_ctr_drbg_free(&drbg);
        mbedtls_entropy_free(&entropy);
        if (fd >= 0) close(fd);
    }

    void rnd(void* p, size_t n) { mbedtls_ctr_drbg_random(&drbg, (uint8_t*)p, n); }

    std::string rndToken(size_t n) {
        static const char* a = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        std::string s;
        uint8_t b[64];
        rnd(b, n);
        for (size_t i = 0; i < n; i++) s += a[b[i] % 64];
        return s;
    }

    bool makeCert() {
        int e;
        if ((e = mbedtls_pk_setup(&key, mbedtls_pk_info_from_type(MBEDTLS_PK_ECKEY))) != 0) { failReason = "pk_setup " + std::to_string(e); return false; }
        if ((e = mbedtls_ecp_gen_key(MBEDTLS_ECP_DP_SECP256R1, mbedtls_pk_ec(key), mbedtls_ctr_drbg_random, &drbg)) != 0) { failReason = "ecp_gen " + std::to_string(e); return false; }
        mbedtls_x509write_cert w;
        mbedtls_x509write_crt_init(&w);
        mbedtls_x509write_crt_set_version(&w, MBEDTLS_X509_CRT_VERSION_3);
        mbedtls_x509write_crt_set_md_alg(&w, MBEDTLS_MD_SHA256);
        mbedtls_x509write_crt_set_subject_key(&w, &key);
        mbedtls_x509write_crt_set_issuer_key(&w, &key);
        mbedtls_x509write_crt_set_subject_name(&w, "CN=dtd-broadcaster");
        mbedtls_x509write_crt_set_issuer_name(&w, "CN=dtd-broadcaster");
        uint8_t serial[8];
        rnd(serial, 8);
        serial[0] &= 0x7F;
        mbedtls_x509write_crt_set_serial_raw(&w, serial, 8);
        mbedtls_x509write_crt_set_validity(&w, "20240101000000", "20350101000000");
        uint8_t buf[2048];
        int n = mbedtls_x509write_crt_der(&w, buf, sizeof buf, mbedtls_ctr_drbg_random, &drbg);
        mbedtls_x509write_crt_free(&w);
        if (n <= 0) { failReason = "crt_der " + std::to_string(n); return false; }
        if ((e = mbedtls_x509_crt_parse_der(&cert, buf + sizeof buf - n, n)) != 0) { failReason = "crt_parse " + std::to_string(e); return false; }
        uint8_t h[32];
        mbedtls_md(mbedtls_md_info_from_type(MBEDTLS_MD_SHA256), cert.raw.p, cert.raw.len, h);
        localFingerprint = hexColon(h, 32);
        return true;
    }

    void setState(State s, const std::string& info = "") {
        state = s;
        if (owner && owner->onState) owner->onState(s, info);
    }

    void fail(const std::string& why) {
        failReason = why;
        running = false;
        setState(State::Failed, why);
    }

    // -------------------------------------------------------------- SDP
    std::string offer() {
        std::ostringstream s;
        uint64_t sid;
        rnd(&sid, sizeof sid);
        sid &= 0x7FFFFFFFFFFFull;
        s << "v=0\r\no=- " << sid << " 2 IN IP4 127.0.0.1\r\ns=-\r\nt=0 0\r\n";
        s << "a=group:BUNDLE";
        if (opt.audio) s << " 0";
        if (opt.video) s << (opt.audio ? " 1" : " 0");
        s << "\r\na=msid-semantic: WMS dtd\r\n";
        auto common = [&](const char* mid) {
            s << "c=IN IP4 0.0.0.0\r\na=rtcp:9 IN IP4 0.0.0.0\r\n";
            s << "a=ice-ufrag:" << localUfrag << "\r\na=ice-pwd:" << localPwd << "\r\n";
            s << "a=fingerprint:sha-256 " << localFingerprint << "\r\na=setup:actpass\r\n";
            s << "a=mid:" << mid << "\r\na=sendonly\r\na=rtcp-mux\r\n";
        };
        if (opt.audio) {
            s << "m=audio 9 UDP/TLS/RTP/SAVPF " << opusPt << "\r\n";
            common("0");
            s << "a=msid:dtd audio0\r\n";
            s << "a=rtpmap:" << opusPt << " opus/48000/2\r\n";
            s << "a=fmtp:" << opusPt << " minptime=10;useinbandfec=1" << (opt.audioChannels > 1 ? ";stereo=1;sprop-stereo=1" : "") << "\r\n";
            s << "a=ssrc:" << audioSsrc << " cname:dtd\r\na=ssrc:" << audioSsrc << " msid:dtd audio0\r\n";
        }
        if (opt.video) {
            s << "m=video 9 UDP/TLS/RTP/SAVPF " << h264Pt << "\r\n";
            common(opt.audio ? "1" : "0");
            s << "a=msid:dtd video0\r\na=rtcp-rsize\r\n";
            s << "a=rtpmap:" << h264Pt << " H264/90000\r\n";
            s << "a=rtcp-fb:" << h264Pt << " nack\r\na=rtcp-fb:" << h264Pt << " nack pli\r\na=rtcp-fb:" << h264Pt << " ccm fir\r\n";
            s << "a=fmtp:" << h264Pt << " level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=" << opt.h264ProfileLevelId << "\r\n";
            s << "a=ssrc:" << videoSsrc << " cname:dtd\r\na=ssrc:" << videoSsrc << " msid:dtd video0\r\n";
        }
        return s.str();
    }

    std::string answer(const std::string& sdp) {
        std::istringstream in(sdp);
        std::string line, media;
        std::map<int, std::string> rtpmap;
        int ansOpus = -1, ansH264 = -1;
        std::string setup;
        while (std::getline(in, line)) {
            line = trim(line);
            if (line.rfind("m=", 0) == 0) { media = line.substr(2, 5); continue; }
            if (line.rfind("a=", 0) != 0) continue;
            std::string a = line.substr(2);
            auto val = [&](const char* k) -> std::string {
                size_t n = strlen(k);
                return a.compare(0, n, k) == 0 ? trim(a.substr(n)) : std::string();
            };
            if (auto v = val("ice-ufrag:"); !v.empty()) remoteUfrag = v;
            else if (auto v = val("ice-pwd:"); !v.empty()) remotePwd = v;
            else if (auto v = val("fingerprint:"); !v.empty()) {
                size_t sp = v.find(' ');
                if (sp != std::string::npos) { remoteFpAlg = lower(v.substr(0, sp)); remoteFp = lower(trim(v.substr(sp + 1))); }
            } else if (auto v = val("setup:"); !v.empty()) setup = lower(v);
            else if (auto v = val("rtpmap:"); !v.empty()) {
                int pt = atoi(v.c_str());
                std::string codec = lower(v.substr(v.find(' ') + 1));
                if (codec.rfind("opus/", 0) == 0 && ansOpus < 0) ansOpus = pt;
                if (codec.rfind("h264/", 0) == 0 && ansH264 < 0) ansH264 = pt;
            } else if (auto v = val("candidate:"); !v.empty()) {
                std::istringstream cs(v);
                std::string found, comp, proto, prio, ip, port, typ, ctype;
                cs >> found >> comp >> proto >> prio >> ip >> port >> typ >> ctype;
                if (comp != "1" || lower(proto) != "udp") continue;
                addrinfo hints{}, *res = nullptr;
                hints.ai_socktype = SOCK_DGRAM;
                hints.ai_family = AF_UNSPEC;
                if (getaddrinfo(ip.c_str(), port.c_str(), &hints, &res) != 0 || !res) continue;
                Candidate c;
                memcpy(&c.addr, res->ai_addr, res->ai_addrlen);
                c.priority = (uint32_t)strtoul(prio.c_str(), nullptr, 10);
                c.type = ctype;
                freeaddrinfo(res);
                cands.push_back(c);
            }
        }
        if (remoteUfrag.empty() || remotePwd.empty()) return "answer thiếu ice-ufrag/ice-pwd";
        if (remoteFp.empty()) return "answer thiếu fingerprint";
        if (cands.empty()) return "answer không có ICE candidate UDP (máy chủ cần IP công khai hoặc cấu hình candidate)";
        if (opt.audio && ansOpus >= 0) opusPt = ansOpus;
        if (opt.video && ansH264 >= 0) h264Pt = ansH264;
        if (opt.video && ansH264 < 0) return "máy chủ không nhận H.264";
        dtlsClient = setup != "active";
        // ưu tiên IPv4, độ ưu tiên cao
        std::stable_sort(cands.begin(), cands.end(), [](const Candidate& a, const Candidate& b) {
            if (a.addr.ss_family != b.addr.ss_family) return a.addr.ss_family == AF_INET;
            return a.priority > b.priority;
        });
        return "";
    }

    // -------------------------------------------------------------- mạng
    bool openSocket() {
        int fam = cands.front().addr.ss_family;
        fd = socket(fam, SOCK_DGRAM, 0);
        if (fd < 0) return false;
        int fl = fcntl(fd, F_GETFL, 0);
        fcntl(fd, F_SETFL, fl | O_NONBLOCK);
        int sz = 1 << 20;
        setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &sz, sizeof sz);
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &sz, sizeof sz);
#ifdef SO_NOSIGPIPE
        int one = 1;
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
#endif
        return true;
    }

    void sendTo(const uint8_t* p, size_t n, const sockaddr_storage& a) {
        ssize_t r = sendto(fd, p, n, 0, (const sockaddr*)&a, addrLen(a));
        if (r > 0) {
            std::lock_guard<std::mutex> l(stMtx);
            st.bytesSent += (uint64_t)r;
            st.packetsSent++;
        }
    }

    void sendBinding(size_t ci) {
        uint8_t txid[12];
        rnd(txid, 12);
        std::string user = remoteUfrag + ":" + localUfrag;
        Bytes prio; put32(prio, (110u << 24) | (65535u << 8) | 255u);
        Bytes tb; put32(tb, uint32_t(tieBreaker >> 32)); put32(tb, uint32_t(tieBreaker));
        auto m = stunBuild(0x0001, txid, {{0x0006, Bytes(user.begin(), user.end())}, {0x0024, prio}, {0x802A, tb}, {0x0025, {}}}, remotePwd);
        pendingTx[std::string((char*)txid, 12)] = ci;
        if (pendingTx.size() > 256) pendingTx.erase(pendingTx.begin());
        sendTo(m.data(), m.size(), cands[ci].addr);
    }

    void handleStun(const uint8_t* p, size_t n, const sockaddr_storage& from) {
        if (n < 20 || get32(p + 4) != kMagic) return;
        uint16_t type = get16(p);
        std::string txid((const char*)p + 8, 12);
        if (type == 0x0101) {   // binding success
            auto it = pendingTx.find(txid);
            if (it == pendingTx.end()) return;
            lastStunResp = Clock::now();
            if (!haveSelected) {
                selected = cands[it->second].addr;
                haveSelected = true;
                startDtls();
            }
        } else if (type == 0x0001) {   // máy chủ (full ICE) kiểm tra ngược → trả lời
            auto x = xorMapped(from);
            if (from.ss_family == AF_INET6) for (int i = 4; i < 16; i++) x[4 + i] ^= (uint8_t)p[8 + i - 4];
            auto m = stunBuild(0x0101, p + 8, {{0x0020, x}}, localPwd);
            sendTo(m.data(), m.size(), from);
            if (!haveSelected) { selected = from; haveSelected = true; startDtls(); }
        } else if (type == 0x0111) {
            fail("ICE bị máy chủ từ chối (sai ufrag/pwd)");
        }
    }

    // -------------------------------------------------------------- DTLS
    static int bioSend(void* ctx, const unsigned char* buf, size_t len) {
        auto* self = (Impl*)ctx;
        if (!self->haveSelected) return MBEDTLS_ERR_SSL_WANT_WRITE;
        self->sendTo(buf, len, self->selected);
        return (int)len;
    }
    static int bioRecv(void* ctx, unsigned char* buf, size_t len) {
        auto* self = (Impl*)ctx;
        if (self->dtlsIn.empty()) return MBEDTLS_ERR_SSL_WANT_READ;
        auto p = std::move(self->dtlsIn.front());
        self->dtlsIn.pop_front();
        size_t n = std::min(len, p.size());
        memcpy(buf, p.data(), n);
        return (int)n;
    }
    static int verifyCb(void*, mbedtls_x509_crt*, int, uint32_t* flags) { *flags = 0; return 0; }   // tự ký: kiểm fingerprint sau
    static void exportKeys(void* ctx, mbedtls_ssl_key_export_type type, const unsigned char* secret, size_t slen,
                           const unsigned char cr[32], const unsigned char sr[32], mbedtls_tls_prf_types prf) {
        auto* self = (Impl*)ctx;
        if (type != MBEDTLS_SSL_KEY_EXPORT_TLS12_MASTER_SECRET || slen != 48) return;
        memcpy(self->masterSecret, secret, 48);
        memcpy(self->randBytes, cr, 32);
        memcpy(self->randBytes + 32, sr, 32);
        self->prfType = prf;
        self->keysExported = true;
    }

    Clock::time_point dtlsStart{};

    void startDtls() {
        setState(State::Handshaking);
        dtlsStart = Clock::now();
        mbedtls_ssl_config_defaults(&conf, dtlsClient ? MBEDTLS_SSL_IS_CLIENT : MBEDTLS_SSL_IS_SERVER,
                                    MBEDTLS_SSL_TRANSPORT_DATAGRAM, MBEDTLS_SSL_PRESET_DEFAULT);
        mbedtls_ssl_conf_rng(&conf, mbedtls_ctr_drbg_random, &drbg);
        mbedtls_ssl_conf_authmode(&conf, dtlsClient ? MBEDTLS_SSL_VERIFY_OPTIONAL : MBEDTLS_SSL_VERIFY_REQUIRED);
        mbedtls_ssl_conf_verify(&conf, verifyCb, nullptr);
        mbedtls_ssl_conf_ca_chain(&conf, &cert, nullptr);
        mbedtls_ssl_conf_own_cert(&conf, &cert, &key);
        mbedtls_ssl_conf_max_tls_version(&conf, MBEDTLS_SSL_VERSION_TLS1_2);
        static const mbedtls_ssl_srtp_profile profiles[] = {MBEDTLS_TLS_SRTP_AES128_CM_HMAC_SHA1_80, MBEDTLS_TLS_SRTP_UNSET};
        mbedtls_ssl_conf_dtls_srtp_protection_profiles(&conf, profiles);
        mbedtls_ssl_conf_handshake_timeout(&conf, 400, 4000);
        if (!dtlsClient) mbedtls_ssl_conf_dtls_cookies(&conf, nullptr, nullptr, nullptr);
        mbedtls_ssl_setup(&ssl, &conf);
        mbedtls_ssl_set_bio(&ssl, this, bioSend, bioRecv, nullptr);
        mbedtls_ssl_set_timer_cb(&ssl, &timer, mbedtls_timing_set_delay, mbedtls_timing_get_delay);
        mbedtls_ssl_set_mtu(&ssl, 1200);
        mbedtls_ssl_set_export_keys_cb(&ssl, exportKeys, this);
        stepDtls();
    }

    void stepDtls() {
        int r = mbedtls_ssl_handshake(&ssl);
        if (r == MBEDTLS_ERR_SSL_WANT_READ || r == MBEDTLS_ERR_SSL_WANT_WRITE) return;
        if (r != 0) {
            char e[128];
            mbedtls_strerror(r, e, sizeof e);
            fail(std::string("DTLS lỗi: ") + e);
            return;
        }
        // kiểm vân tay chứng chỉ của máy chủ
        const mbedtls_x509_crt* peer = mbedtls_ssl_get_peer_cert(&ssl);
        if (!peer) { fail("DTLS: máy chủ không gửi chứng chỉ"); return; }
        mbedtls_md_type_t mt = remoteFpAlg == "sha-1" ? MBEDTLS_MD_SHA1 : remoteFpAlg == "sha-512" ? MBEDTLS_MD_SHA512 :
                               remoteFpAlg == "sha-384" ? MBEDTLS_MD_SHA384 : MBEDTLS_MD_SHA256;
        const mbedtls_md_info_t* mi = mbedtls_md_info_from_type(mt);
        uint8_t h[64];
        mbedtls_md(mi, peer->raw.p, peer->raw.len, h);
        if (lower(hexColon(h, mbedtls_md_get_size(mi))) != remoteFp) { fail("DTLS: fingerprint máy chủ không khớp SDP"); return; }
        mbedtls_dtls_srtp_info si;
        mbedtls_ssl_get_dtls_srtp_negotiation_result(&ssl, &si);
        if (si.private_chosen_dtls_srtp_profile != MBEDTLS_TLS_SRTP_AES128_CM_HMAC_SHA1_80) { fail("DTLS: máy chủ không chọn SRTP AES128_CM_HMAC_SHA1_80"); return; }
        if (!keysExported) { fail("DTLS: không lấy được khoá"); return; }
        uint8_t km[60];
        if (mbedtls_ssl_tls_prf(prfType, masterSecret, 48, "EXTRACTOR-dtls_srtp", randBytes, 64, km, 60) != 0) { fail("DTLS: PRF lỗi"); return; }
        const uint8_t *ck = km, *sk = km + 16, *cs = km + 32, *ss = km + 46;
        {
            std::lock_guard<std::mutex> l(tx);
            if (dtlsClient) { out.init(ck, cs); in.init(sk, ss); } else { out.init(sk, ss); in.init(ck, cs); }
        }
        lastStunResp = Clock::now();
        setState(State::Connected);
        if (owner && owner->onKeyframeRequest) owner->onKeyframeRequest();
    }

    // -------------------------------------------------------------- RTP
    uint32_t rtpTs(int64_t ptsUs, int clock, uint32_t offset) {
        if (baseUs == INT64_MIN) baseUs = ptsUs;
        return offset + (uint32_t)((ptsUs - baseUs) * clock / 1000000);
    }

    void sendRtpLocked(bool video, bool marker, uint32_t ts, const uint8_t* pl, size_t n, const uint8_t* pre = nullptr, size_t preN = 0) {
        Bytes p;
        p.reserve(12 + preN + n + 10);
        p.push_back(0x80);
        p.push_back((marker ? 0x80 : 0) | (video ? h264Pt : opusPt));
        uint16_t& seq = video ? vSeq : aSeq;
        uint32_t& roc = video ? vRoc : aRoc;
        put16(p, seq);
        put32(p, ts);
        put32(p, video ? videoSsrc : audioSsrc);
        if (preN) p.insert(p.end(), pre, pre + preN);
        p.insert(p.end(), pl, pl + n);
        Last& L = video ? lastV : lastA;
        L.packets++; L.octets += uint32_t(preN + n); L.rtp = ts; L.wall = Clock::now(); L.any = true;
        out.protectRtp(p, roc);
        if (video) { history[seq % 1024] = p; historySeq[seq % 1024] = seq; }
        if (++seq == 0) roc++;
        sendTo(p.data(), p.size(), selected);
    }

    void video(const uint8_t* d, size_t len, int64_t ptsUs, bool key, const std::vector<Bytes>& sps, const std::vector<Bytes>& pps) {
        std::lock_guard<std::mutex> l(tx);
        if (state != State::Connected || !out.ready) return;
        uint32_t ts = rtpTs(ptsUs, 90000, tsOffsetV);
        std::vector<std::pair<const uint8_t*, size_t>> nal;
        for (size_t i = 0; i + 4 <= len;) {
            size_t n = get32(d + i);
            i += 4;
            if (n == 0 || i + n > len) break;
            uint8_t t = d[i] & 0x1F;
            if (t != 9 && !(key && (t == 7 || t == 8))) nal.push_back({d + i, n});
            i += n;
        }
        const size_t maxPl = size_t(opt.mtu) - 12 - 10;
        if (key && !sps.empty() && !pps.empty()) {   // STAP-A: SPS + PPS
            Bytes stap{uint8_t(0x78)};
            for (auto* v : {&sps, &pps}) for (auto& x : *v) { put16(stap, (uint16_t)x.size()); stap.insert(stap.end(), x.begin(), x.end()); }
            if (stap.size() <= maxPl) sendRtpLocked(true, false, ts, stap.data(), stap.size());
        }
        for (size_t k = 0; k < nal.size(); k++) {
            bool last = k + 1 == nal.size();
            const uint8_t* n = nal[k].first;
            size_t sz = nal[k].second;
            if (sz <= maxPl) { sendRtpLocked(true, last, ts, n, sz); continue; }
            uint8_t ind = (n[0] & 0xE0) | 28;
            for (size_t off = 1; off < sz;) {
                size_t c = std::min(maxPl - 2, sz - off);
                uint8_t fu = n[0] & 0x1F;
                if (off == 1) fu |= 0x80;
                bool end = off + c >= sz;
                if (end) fu |= 0x40;
                uint8_t pre[2] = {ind, fu};
                sendRtpLocked(true, last && end, ts, n + off, c, pre, 2);
                off += c;
            }
        }
    }

    void audio(const uint8_t* d, size_t n, int64_t ptsUs) {
        std::lock_guard<std::mutex> l(tx);
        if (state != State::Connected || !out.ready) return;
        if (opt.video && baseUs == INT64_MIN) return;    // đợi hình để chung mốc
        sendRtpLocked(false, false, rtpTs(ptsUs, 48000, tsOffsetA), d, n);
    }

    // -------------------------------------------------------------- RTCP
    static void ntpNow(uint32_t& msw, uint32_t& lsw) {
        using namespace std::chrono;
        auto us = duration_cast<microseconds>(system_clock::now().time_since_epoch()).count();
        double s = double(us) / 1e6 + 2208988800.0;
        msw = uint32_t(uint64_t(s));
        lsw = uint32_t((s - double(uint64_t(s))) * 4294967296.0);
    }

    void sendReports() {
        std::lock_guard<std::mutex> l(tx);
        if (!out.ready) return;
        for (bool v : {true, false}) {
            Last& L = v ? lastV : lastA;
            if (!L.any) continue;
            uint32_t msw, lsw;
            ntpNow(msw, lsw);
            int clock = v ? 90000 : 48000;
            double el = std::chrono::duration<double>(Clock::now() - L.wall).count();
            uint32_t rtp = L.rtp + uint32_t(el * clock);
            uint32_t ssrc = v ? videoSsrc : audioSsrc;
            Bytes p{0x80, 200, 0, 6};
            put32(p, ssrc); put32(p, msw); put32(p, lsw); put32(p, rtp); put32(p, L.packets); put32(p, L.octets);
            // SDES CNAME
            const char* cname = "dtd";
            Bytes sd{0x81, 202, 0, 0};
            put32(sd, ssrc);
            sd.push_back(1); sd.push_back((uint8_t)strlen(cname));
            sd.insert(sd.end(), cname, cname + strlen(cname));
            sd.push_back(0);
            while (sd.size() % 4) sd.push_back(0);
            uint16_t wl = uint16_t(sd.size() / 4 - 1);
            sd[2] = wl >> 8; sd[3] = wl & 0xFF;
            p.insert(p.end(), sd.begin(), sd.end());
            srSent[(msw << 16) | (lsw >> 16)] = Clock::now();
            if (srSent.size() > 32) srSent.erase(srSent.begin());
            out.protectRtcp(p, srtcpIndex++ & 0x7FFFFFFF);
            sendTo(p.data(), p.size(), selected);
        }
    }

    void handleRtcp(Bytes pkt) {
        if (!in.ready || !in.unprotectRtcp(pkt)) return;
        size_t i = 0;
        while (i + 4 <= pkt.size()) {
            uint8_t fmt = pkt[i] & 0x1F, pt = pkt[i + 1];
            size_t len = (size_t(get16(&pkt[i + 2])) + 1) * 4;
            if (i + len > pkt.size()) break;
            const uint8_t* b = &pkt[i];
            if (pt == 201 && len >= 8) {   // RR
                for (size_t k = 0; k < fmt && 8 + k * 24 + 24 <= len; k++) {
                    const uint8_t* r = b + 8 + k * 24;
                    uint32_t lsr = get32(r + 16), dlsr = get32(r + 20);
                    std::lock_guard<std::mutex> l(stMtx);
                    st.fractionLost = r[4] / 256.0;
                    auto it = srSent.find(lsr);
                    if (lsr && it != srSent.end()) {
                        double rtt = std::chrono::duration<double, std::milli>(Clock::now() - it->second).count() - dlsr / 65.536;
                        if (rtt >= 0) st.rttMs = rtt;
                    }
                }
            } else if (pt == 205 && fmt == 1 && len >= 16) {   // NACK
                std::lock_guard<std::mutex> l(tx);
                for (size_t k = 12; k + 4 <= len; k += 4) {
                    uint16_t pid = get16(b + k), blp = get16(b + k + 2);
                    for (int bit = -1; bit < 16; bit++) {
                        if (bit >= 0 && !(blp & (1 << bit))) continue;
                        uint16_t s = uint16_t(pid + (bit + 1));
                        auto& h = history[s % 1024];
                        if (!h.empty() && historySeq[s % 1024] == s) {
                            sendTo(h.data(), h.size(), selected);
                            std::lock_guard<std::mutex> l2(stMtx);
                            st.retransmitted++;
                        }
                    }
                    std::lock_guard<std::mutex> l2(stMtx);
                    st.nacksReceived++;
                }
            } else if (pt == 206 && (fmt == 1 || fmt == 4)) {   // PLI / FIR
                auto now = Clock::now();
                if (now - lastPli > std::chrono::milliseconds(300)) {
                    lastPli = now;
                    { std::lock_guard<std::mutex> l(stMtx); st.keyframeRequests++; }
                    if (owner && owner->onKeyframeRequest) owner->onKeyframeRequest();
                }
            }
            i += len;
        }
    }

    // -------------------------------------------------------------- vòng lặp
    void run() {
        auto t0 = Clock::now();
        auto lastCheck = Clock::time_point{}, lastSR = Clock::time_point{}, lastConsent = Clock::now();
        size_t rr = 0;
        uint8_t buf[2048];
        while (running) {
            auto now = Clock::now();
            State s = state;
            if (s == State::Checking) {
                if (now - lastCheck > std::chrono::milliseconds(50)) {
                    lastCheck = now;
                    sendBinding(rr++ % cands.size());
                }
                if (now - t0 > std::chrono::seconds(15)) { fail("ICE: không tới được máy chủ qua UDP (tường lửa?)"); break; }
            } else if (s == State::Handshaking) {
                if (now - dtlsStart > std::chrono::seconds(15)) { fail("DTLS: hết thời gian bắt tay"); break; }
            } else if (s == State::Connected) {
                if (now - lastSR > std::chrono::seconds(1)) { lastSR = now; sendReports(); }
                if (now - lastConsent > std::chrono::milliseconds(2500)) {
                    lastConsent = now;
                    for (size_t i = 0; i < cands.size(); i++) if (sameAddr(cands[i].addr, selected)) { sendBinding(i); break; }
                }
                if (now - lastStunResp > std::chrono::seconds(30)) { fail("Mất kết nối WebRTC (không còn phản hồi)"); break; }
            }
            pollfd pf{fd, POLLIN, 0};
            if (poll(&pf, 1, 10) > 0) {
                for (int k = 0; k < 64; k++) {
                    sockaddr_storage from{};
                    socklen_t fl = sizeof from;
                    ssize_t n = recvfrom(fd, buf, sizeof buf, 0, (sockaddr*)&from, &fl);
                    if (n <= 0) break;
                    uint8_t b0 = buf[0];
                    if (b0 < 4) handleStun(buf, (size_t)n, from);
                    else if (b0 >= 20 && b0 < 64) {
                        if (!haveSelected) { selected = from; haveSelected = true; startDtls(); }
                        dtlsIn.emplace_back(buf, buf + n);
                    } else if (b0 >= 128 && b0 < 192 && n >= 8 && buf[1] >= 192 && buf[1] <= 223) {
                        handleRtcp(Bytes(buf, buf + n));
                    }
                }
            }
            if (state == State::Handshaking) stepDtls();
            else if (state == State::Connected && !dtlsIn.empty()) {
                uint8_t tmp[256];
                int r = mbedtls_ssl_read(&ssl, tmp, sizeof tmp);   // close_notify / dữ liệu thừa
                if (r == MBEDTLS_ERR_SSL_PEER_CLOSE_NOTIFY) { fail("Máy chủ đóng phiên WebRTC"); break; }
            }
        }
    }
};

// ---------------------------------------------------------------------------
WhipClient::WhipClient(const Options& o) : d(new Impl) {
    d->opt = o;
    d->owner = this;
    d->localUfrag = d->rndToken(8);
    d->localPwd = d->rndToken(24);
    d->rnd(&d->tieBreaker, 8);
    d->rnd(&d->audioSsrc, 4);
    d->rnd(&d->videoSsrc, 4);
    d->rnd(&d->vSeq, 2);
    d->rnd(&d->aSeq, 2);
    d->rnd(&d->tsOffsetV, 4);
    d->rnd(&d->tsOffsetA, 4);
    if (!d->audioSsrc) d->audioSsrc = 1;
    if (!d->videoSsrc) d->videoSsrc = 2;
}

WhipClient::~WhipClient() { stop(); }

std::string WhipClient::createOffer() {
    if (d->localFingerprint.empty() && !d->makeCert()) {
        if (onState) onState(State::Failed, "không tạo được chứng chỉ DTLS: " + d->failReason);
        return "";
    }
    return d->offer();
}

std::string WhipClient::setAnswer(const std::string& sdp) { return d->answer(sdp); }

bool WhipClient::start() {
    if (d->running || d->cands.empty()) return false;
    if (!d->openSocket()) return false;
    d->running = true;
    d->setState(State::Checking);
    d->worker = std::thread([this] { d->run(); });
    return true;
}

void WhipClient::stop() {
    if (d->worker.joinable()) {
        bool wasRunning = d->running.exchange(false);
        d->worker.join();
        if (wasRunning && d->state == State::Connected) {
            mbedtls_ssl_close_notify(&d->ssl);
        }
        if (d->state != State::Failed) d->setState(State::Closed);
    }
}

void WhipClient::sendVideo(const uint8_t* avcc, size_t len, int64_t ptsUs, bool keyframe,
                           const std::vector<std::vector<uint8_t>>& sps, const std::vector<std::vector<uint8_t>>& pps) {
    if (d->opt.video) d->video(avcc, len, ptsUs, keyframe, sps, pps);
}

void WhipClient::sendOpus(const uint8_t* data, size_t len, int64_t ptsUs) {
    if (d->opt.audio) d->audio(data, len, ptsUs);
}

WhipClient::State WhipClient::state() const { return d->state; }

WhipStats WhipClient::stats() const {
    std::lock_guard<std::mutex> l(d->stMtx);
    return d->st;
}

} // namespace srtkit
