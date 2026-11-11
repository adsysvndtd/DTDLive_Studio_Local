// Talkback end-to-end: SrtBroadcaster (audio-only, chế độ listener) phát AAC,
// TalkbackReceiver (caller = pull) nhận, tách và phát theo nhịp.
// test_talkback <audio.adts> <port> [giây]
#include <atomic>
#include <chrono>
#include <cstdio>
#include <thread>

#include "media_util.h"
#include "srtkit/SrtBroadcaster.h"
#include "srtkit/TalkbackReceiver.h"

using namespace srtkit;

int main(int argc, char** argv) {
    if (argc < 3) return 2;
    auto audio = loadAdts(argv[1]);
    int port = std::atoi(argv[2]);
    int seconds = argc > 3 ? std::atoi(argv[3]) : 6;

    StreamParams sp;
    sp.hasAudio = true;
    BroadcasterCallbacks cb;
    cb.onState = [](int id, ConnState s, const std::string& i) { std::printf("[src %d] %s %s\n", id, toString(s), i.c_str()); };
    SrtBroadcaster src(sp, cb);
    ConnectionConfig cc;
    cc.name = "talkback-src";
    cc.content = ContentMode::AudioOnly;
    cc.srt.mode = SrtMode::Listener;
    cc.srt.port = port;
    cc.srt.latencyMs = 200;
    cc.srt.passphrase = "talkback-secret";
    src.addConnection(cc);
    src.start();

    std::atomic<int> played{0};
    std::atomic<int64_t> firstPts{-1}, lastPts{0};
    TalkbackReceiver::Config tc;
    tc.srt.host = "127.0.0.1";
    tc.srt.port = port;
    tc.srt.mode = SrtMode::Caller;
    tc.srt.latencyMs = 200;
    tc.srt.passphrase = "talkback-secret";
    tc.bufferMs = 300;
    TalkbackReceiver::Callbacks tcb;
    tcb.onState = [](ConnState s, const std::string& i) { std::printf("[talkback] %s %s\n", toString(s), i.c_str()); };
    tcb.onAudio = [&](const DemuxedAudioFrame& f) {
        if (firstPts < 0) firstPts = f.ptsUs;
        lastPts = f.ptsUs;
        if (++played == 1) std::printf("[talkback] first frame: %d Hz %d ch, %zu bytes, asc=%02x%02x\n",
                                       f.sampleRate, f.channels, f.data.size(), f.asc[0], f.asc[1]);
    };
    TalkbackReceiver rx(tc, tcb);
    rx.start();

    const int64_t aacUs = 1024LL * 1000000 / 48000;
    auto t0 = std::chrono::steady_clock::now();
    int64_t apts = 0;
    size_t ai = 0;
    while (true) {
        int64_t now = std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now() - t0).count();
        if (now > seconds * 1000000LL) break;
        if (apts <= now) {
            auto& a = audio[ai++ % audio.size()];
            src.pushAudio(a.raw.data(), a.raw.size(), apts);
            apts += aacUs;
        } else {
            std::this_thread::sleep_for(std::chrono::milliseconds(2));
        }
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(800));
    rx.stop();
    src.stop();
    double expected = seconds * 48000.0 / 1024.0;
    std::printf("TALKBACK received=%llu played=%d late=%llu expected~%.0f span=%.2fs\n",
                (unsigned long long)rx.framesReceived(), played.load(), (unsigned long long)rx.framesLate(), expected,
                (lastPts - firstPts) / 1e6);
    return played > expected * 0.7 ? 0 : 1;
}
