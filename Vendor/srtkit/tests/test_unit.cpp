// Unit test không cần mạng: URL, ABR (3 chế độ), mux/demux TS (AAC, Opus), SEI timecode.
#include <cassert>
#include <cstdio>
#include <cstring>
#include <map>

#include "srtkit/AbrController.h"
#include "srtkit/Timecode.h"
#include "srtkit/TsDemuxer.h"
#include "srtkit/TsMuxer.h"

using namespace srtkit;

static int failures = 0;
#define CHECK(c) do { if (!(c)) { std::printf("FAIL %s:%d %s\n", __FILE__, __LINE__, #c); ++failures; } } while (0)

static void testUrl() {
    SrtOptions o;
    std::string err;
    CHECK(parseSrtUrl("srt://10.0.0.1:9000?mode=caller&latency=500&passphrase=0123456789ab&pbkeylen=32&streamid=%23!%3A%3Ar%3Dlive%2Fcam1%2Cm%3Dpublish", o, &err));
    CHECK(o.host == "10.0.0.1" && o.port == 9000 && o.latencyMs == 500 && o.pbKeyLen == 32);
    CHECK(o.streamId == "#!::r=live/cam1,m=publish");
    CHECK(parseSrtUrl("srt://[::1]:7000?mode=listener", o, &err) && o.host == "::1" && o.mode == SrtMode::Listener);
    CHECK(parseSrtUrl("srt://h:1?srtmode=r&srtlatency=120", o, &err) && o.mode == SrtMode::Rendezvous && o.latencyMs == 120);
    CHECK(!parseSrtUrl("srt://h:1?passphrase=short", o, &err));
    CHECK(!parseSrtUrl("rtmp://h:1", o, &err));
    std::printf("url ok\n");
}

// Mô phỏng: mỗi giây gửi `rate` gói, mất `loss` gói
struct Sim {
    AbrController& a; int64_t t = 0, sent = 0, lost = 0;
    bool step(int rate, int loss) { t += 1000; sent += rate; lost += loss; return a.onSample({t, sent, lost, 0}); }
};

static void testAbrLog() {
    AbrController a(AbrMode::LogarithmicDescend, 4000000, 30, true);
    a.reset(0);
    Sim s{a};
    s.step(300, 0);
    for (int i = 0; i < 3; ++i) s.step(300, 1);     // 3 gói / 3 s: chưa đủ ngưỡng 4
    CHECK(a.bitrate() == 4000000);
    s.step(300, 1);                                  // gói thứ 4 -> hạ 1 bậc (75%)
    CHECK(a.bitrate() == 3000000);
    CHECK(a.fps() == 30);
    for (int i = 0; i < 3; ++i) { for (int k = 0; k < 4; ++k) s.step(300, 1); }
    CHECK(a.bitrate() < 1500000 && a.bitrate() >= 1000000);  // sàn 25% = 1 Mbps
    CHECK(a.fps() == 15);                            // variable FPS: dưới 50% -> 1/2
    int b = a.bitrate();
    for (int i = 0; i < 59; ++i) s.step(300, 0);
    CHECK(a.bitrate() == b);                         // chưa đủ 60 s
    s.step(300, 0);
    CHECK(a.bitrate() > b);                          // nâng lại 1 bậc sau 1 phút
    std::printf("abr log ok (%d -> %d)\n", b, a.bitrate());
}

static void testAbrLadder() {
    AbrController a(AbrMode::LadderAscend, 3000000, 30, false);
    a.reset(0);
    Sim s{a};
    s.step(300, 0);
    // ngưỡng = 3 Mbps / 300000 = 10 gói / 10 s
    for (int i = 0; i < 9; ++i) s.step(300, 1);
    CHECK(a.bitrate() == 3000000);
    s.step(300, 1);
    CHECK(a.bitrate() == 1000000);                   // cắt 2/3
    for (int i = 0; i < 14; ++i) s.step(300, 0);
    CHECK(a.bitrate() == 1000000);
    s.step(300, 0);                                  // 15 s -> 2/3
    CHECK(a.bitrate() == 2000000);
    // Mất gói ngay sau khi nâng (ngưỡng mới = 6) -> cắt, lần thử kế chờ 90 s
    for (int i = 0; i < 6; ++i) s.step(300, 1);
    CHECK(a.bitrate() == 1000000);
    for (int i = 0; i < 30; ++i) s.step(300, 0);
    CHECK(a.bitrate() == 1000000);
    for (int i = 0; i < 60; ++i) s.step(300, 0);
    CHECK(a.bitrate() == 2000000);
    std::printf("abr ladder ok\n");
}

static void testAbrHybrid() {
    AbrController a(AbrMode::Hybrid, 6000000, 30, false);
    a.reset(0);
    Sim s{a};
    s.step(500, 0);
    for (int i = 0; i < 5; ++i) s.step(500, 0);
    s.step(500, 250);                                // 50% gói mất trong cửa sổ? (250/3000 ~ 8%)
    CHECK(a.bitrate() < 6000000 && a.bitrate() > 5000000);
    // Mất nặng liên tục -> giảm dần nhưng không dưới 25%
    for (int i = 0; i < 60; ++i) s.step(500, 400);
    CHECK(a.bitrate() == 1500000);
    // Ổn định: +500 Kbps mỗi 30 s
    int b = a.bitrate();
    for (int i = 0; i < 40; ++i) s.step(500, 0);
    CHECK(a.bitrate() == b + 500000);
    std::printf("abr hybrid ok\n");
}

struct TsCapture {
    std::vector<uint8_t> bytes;
    std::map<int, int> lastCc;
    int ccErrors = 0;
    int64_t lastPcr = -1; int pcrBackwards = 0, pcrCount = 0;
    void add(const uint8_t* p) {
        assert(p[0] == 0x47);
        int pid = ((p[1] & 0x1F) << 8) | p[2];
        int afc = (p[3] >> 4) & 3, cc = p[3] & 0xF;
        if (afc & 1) {
            auto it = lastCc.find(pid);
            if (it != lastCc.end() && ((it->second + 1) & 0xF) != cc) ++ccErrors;
            lastCc[pid] = cc;
        }
        if ((afc & 2) && p[4] >= 7 && (p[5] & 0x10)) {
            int64_t base = ((int64_t)p[6] << 25) | (p[7] << 17) | (p[8] << 9) | (p[9] << 1) | (p[10] >> 7);
            if (lastPcr >= 0 && base < lastPcr) ++pcrBackwards;
            lastPcr = base; ++pcrCount;
        }
        bytes.insert(bytes.end(), p, p + 188);
    }
};

static void testMuxRoundTrip(AudioCodec codec) {
    TsCapture cap;
    TsMuxer::Config mc;
    mc.hasVideo = true;
    mc.audioCodec = codec;
    TsMuxer mux(mc, [&](const uint8_t* p) { cap.add(p); });
    mux.setVideoParameterSets({{0x67, 0x42, 0xC0, 0x1E, 0xDA}, {0x68, 0xCE, 0x3C, 0x80}});
    std::vector<std::vector<uint8_t>> sent;
    for (int i = 0; i < 100; ++i) {
        std::vector<uint8_t> au = {0, 0, 0, 1, static_cast<uint8_t>(i % 30 == 0 ? 0x65 : 0x41)};
        au.resize(5 + 300 + (i * 37) % 4000, static_cast<uint8_t>(i));
        mux.writeVideo(au.data(), au.size(), i * 33333LL, i * 33333LL, i % 30 == 0);
        std::vector<uint8_t> a(50 + (i * 13) % 300 + (codec == AudioCodec::Opus ? 300 : 0), static_cast<uint8_t>(0xA0 + i));
        a[0] = static_cast<uint8_t>(i);
        sent.push_back(a);
        mux.writeAudio(a.data(), a.size(), i * 21333LL);
    }
    CHECK(cap.ccErrors == 0);
    CHECK(cap.pcrBackwards == 0 && cap.pcrCount >= 100);
    std::vector<DemuxedAudioFrame> got;
    TsDemuxer dm([&](const DemuxedAudioFrame& f) { got.push_back(f); });
    // đưa vào theo khối 1316 giống SRT
    for (size_t i = 0; i < cap.bytes.size(); i += 1316)
        dm.feed(cap.bytes.data() + i, std::min<size_t>(1316, cap.bytes.size() - i));
    CHECK(got.size() == sent.size());
    bool same = got.size() == sent.size();
    for (size_t i = 0; same && i < got.size(); ++i) same = got[i].data == sent[i] && got[i].codec == codec;
    CHECK(same);
    if (!got.empty()) CHECK(std::llabs(got[10].ptsUs - 10 * 21333LL - 700000) < 50);
    std::printf("ts roundtrip %s ok (%zu frames, %zu bytes)\n", codec == AudioCodec::AAC ? "aac" : "opus", got.size(), cap.bytes.size());
}

static void testCameraVideo() {
    TsMuxer::Config config;
    config.hasAudio = false;
    TsCapture cap;
    TsMuxer mux(config, [&](const uint8_t* packet) { cap.add(packet); });
    mux.setVideoParameterSets({{0x67, 0x42}, {0x68, 0x80}});
    std::vector<uint8_t> key = {0, 0, 0, 1, 0x65, 0x81};
    std::vector<uint8_t> delta = {0, 0, 1, 0x41, 0x95};
    mux.writeVideo(key.data(), key.size(), 0, 0, true);
    mux.writeVideo(delta.data(), delta.size(), 33333, 33333, false);
    mux.writeVideo(delta.data(), delta.size(), 66666, 66666, false);
    int received = 0;
    TsDemuxer demux({}, [&](const uint8_t* data, size_t size, int64_t pts) {
        std::vector<int> types;
        for (auto& nal : annexb::split(data, size)) types.push_back(annexb::h264Type(nal));
        const bool isKey = received % 2 == 0;
        CHECK(types == (isKey ? std::vector<int>{9, 7, 8, 5} : std::vector<int>{9, 1}));
        CHECK(std::llabs(pts - 700000 - (isKey ? 0 : 33333)) < 15);
        ++received;
    });
    for (int session = 0; session < 2; ++session) {
        demux.reset(); // a partial unbounded PES from the previous sender must be discarded
        for (size_t i = 0; i < cap.bytes.size(); i += 113)
            demux.feed(cap.bytes.data() + i, std::min<size_t>(113, cap.bytes.size() - i));
    }
    CHECK(received == 4);
}

static void testSei() {
    for (VideoCodec c : {VideoCodec::H264, VideoCodec::HEVC}) {
        // giá trị có nhiều byte 0 để kiểm tra emulation prevention
        int64_t t = 1700000000000000LL;
        auto nal = buildTimecodeSei(c, t);
        int64_t back = 0;
        CHECK(parseTimecodeSei(c, nal.data(), nal.size(), back));
        CHECK(std::llabs(back - t) <= 1);
        for (size_t i = 2; i < nal.size(); ++i) CHECK(!(nal[i - 2] == 0 && nal[i - 1] == 0 && nal[i] <= 2));
    }
    std::printf("sei ok\n");
}

int main() {
    testUrl();
    testAbrLog();
    testAbrLadder();
    testAbrHybrid();
    testMuxRoundTrip(AudioCodec::AAC);
    testMuxRoundTrip(AudioCodec::Opus);
    testCameraVideo();
    testSei();
    std::printf(failures ? "UNIT: %d FAILURES\n" : "UNIT: ALL PASSED\n", failures);
    return failures ? 1 : 0;
}
