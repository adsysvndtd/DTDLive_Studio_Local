// Đẩy file H.264/HEVC + AAC lên SRT theo thời gian thực, giả lập encoder trên điện thoại.
// test_publish <video.annexb> <audio.adts|-> <url> [giây] [--hevc] [--content va|a|v] [--abr N]
//              [--vfps] [--sei] [--url2 URL] [--unsent ms]
#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <string>
#include <thread>

#include "media_util.h"
#include "srtkit/SrtBroadcaster.h"

using namespace srtkit;
using Clock = std::chrono::steady_clock;

int main(int argc, char** argv) {
    if (argc < 4) { std::fprintf(stderr, "usage: %s video audio url [sec] [opts]\n", argv[0]); return 2; }
    std::string vpath = argv[1], apath = argv[2], url = argv[3];
    int seconds = argc > 4 && argv[4][0] != '-' ? std::atoi(argv[4]) : 10;
    bool hevc = false, sei = false, vfps = false;
    ContentMode content = ContentMode::VideoAudio;
    AbrMode abr = AbrMode::Off;
    std::string url2;
    int unsent = 0;
    for (int i = 4; i < argc; ++i) {
        std::string a = argv[i];
        if (a == "--hevc") hevc = true;
        else if (a == "--sei") sei = true;
        else if (a == "--vfps") vfps = true;
        else if (a == "--content" && i + 1 < argc) { std::string c = argv[++i]; content = c == "a" ? ContentMode::AudioOnly : c == "v" ? ContentMode::VideoOnly : ContentMode::VideoAudio; }
        else if (a == "--abr" && i + 1 < argc) abr = static_cast<AbrMode>(std::atoi(argv[++i]));
        else if (a == "--url2" && i + 1 < argc) url2 = argv[++i];
        else if (a == "--unsent" && i + 1 < argc) unsent = std::atoi(argv[++i]);
    }

    std::vector<std::vector<uint8_t>> params;
    auto video = loadVideo(vpath, hevc, params);
    std::vector<AudioAU> audio;
    if (apath != "-") audio = loadAdts(apath);
    std::printf("loaded %zu video AU (%zu param sets), %zu audio AU\n", video.size(), params.size(), audio.size());

    StreamParams sp;
    sp.videoCodec = hevc ? VideoCodec::HEVC : VideoCodec::H264;
    sp.videoBitrateBps = 1500000;
    sp.fps = 30;
    sp.hasAudio = !audio.empty();
    sp.audioSampleRate = 48000;
    sp.audioChannels = 2;
    sp.insertNtpSei = sei;
    sp.ntpHost = "time.google.com";

    std::atomic<int> keyReq{0}, bitrateChanges{0};
    BroadcasterCallbacks cb;
    cb.onState = [](int id, ConnState s, const std::string& info) {
        std::printf("[conn %d] %s %s\n", id, toString(s), info.c_str());
        std::fflush(stdout);
    };
    cb.onStats = [](const std::vector<ConnectionStats>& v) {
        for (auto& s : v)
            std::printf("[stats %d] %s up=%llds sent=%lluB %.0fkbps rtt=%.1fms lost=%lld retx=%lld drop=%lld fdrop=%llu recon=%d abr=%d\n",
                        s.id, toString(s.state), (long long)(s.uptimeMs / 1000), (unsigned long long)s.bytesSent, s.sendKbps,
                        s.rttMs, (long long)s.pktLost, (long long)s.pktRetrans, (long long)s.pktDropped,
                        (unsigned long long)s.framesDropped, s.reconnects, s.abrBitrateBps);
        std::fflush(stdout);
    };
    cb.requestKeyframe = [&] { ++keyReq; };
    cb.setEncoderBitrate = [&](int b) { ++bitrateChanges; std::printf("[encoder] bitrate -> %d\n", b); };
    cb.setEncoderFps = [&](int f) { std::printf("[encoder] fps -> %d\n", f); };

    SrtBroadcaster bc(sp, cb);
    auto addUrl = [&](const std::string& u, const char* name) {
        ConnectionConfig cc;
        cc.name = name;
        std::string err;
        if (!parseSrtUrl(u, cc.srt, &err)) { std::fprintf(stderr, "bad url %s: %s\n", u.c_str(), err.c_str()); std::exit(2); }
        cc.content = content;
        cc.abr = abr;
        cc.variableFps = vfps;
        ReconnectPolicy rp;
        rp.reconnectDelayMs = 1000;
        rp.unsentTimeoutMs = unsent;
        return bc.addConnection(cc, rp);
    };
    addUrl(url, "main");
    if (!url2.empty()) addUrl(url2, "backup");
    bc.setVideoParameterSets(params);
    bc.start();

    // Giả lập encoder: video 30 fps, AAC 1024 mẫu @48k. Keyframe theo GOP của file;
    // khi lõi yêu cầu keyframe thì "nhảy" tới keyframe kế tiếp của file (giống ép IDR).
    const int64_t frameUs = 1000000 / 30;
    const int64_t aacUs = 1024LL * 1000000 / 48000;
    auto t0 = Clock::now();
    size_t vi = 0, ai = 0;
    int64_t vpts = 0, apts = 0;
    int64_t endUs = static_cast<int64_t>(seconds) * 1000000;
    int lastKeyReq = 0;
    while (true) {
        int64_t now = std::chrono::duration_cast<std::chrono::microseconds>(Clock::now() - t0).count();
        if (now >= endUs) break;
        bool did = false;
        if (content != ContentMode::AudioOnly && !video.empty() && vpts <= now) {
            if (keyReq != lastKeyReq) {  // ép keyframe
                lastKeyReq = keyReq;
                size_t j = vi;
                for (size_t k = 0; k < video.size(); ++k) { size_t idx = (vi + k) % video.size(); if (video[idx].key) { j = idx; break; } }
                vi = j;
            }
            auto& f = video[vi % video.size()];
            bc.pushVideo(f.data.data(), f.data.size(), 1000000 + vpts, 1000000 + vpts, f.key);
            vi = (vi + 1) % video.size();
            vpts += frameUs;
            did = true;
        }
        if (!audio.empty() && apts <= now) {
            auto& a = audio[ai % audio.size()];
            bc.pushAudio(a.raw.data(), a.raw.size(), 1000000 + apts);
            ai++;
            apts += aacUs;
            did = true;
        }
        if (!did) std::this_thread::sleep_for(std::chrono::milliseconds(2));
    }
    auto st = bc.stats();
    bc.stop();
    for (auto& s : st)
        std::printf("FINAL conn=%d bytes=%llu reconnects=%d framesDropped=%llu\n", s.id,
                    (unsigned long long)s.bytesSent, s.reconnects, (unsigned long long)s.framesDropped);
    std::printf("keyframe requests=%d bitrate changes=%d\n", keyReq.load(), bitrateChanges.load());
    return 0;
}
