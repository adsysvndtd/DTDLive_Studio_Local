// DTD Studio: SRT ingest server — one listener port, many callers. Each caller is identified by its
// SRT streamid (plain "cam1", or the access-control form "#!::r=live/cam1,m=publish"), carries MPEG-TS
// with H.264 / HEVC video and AAC / Opus audio, and is demuxed on its own thread.
#pragma once

#include <atomic>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "srtkit/TsDemuxer.h"

namespace srtkit {

class SrtIngestServer {
public:
    struct Config {
        int port = 9000;
        std::string passphrase;   // empty = no encryption (applies to every caller)
        int pbKeyLen = 16;
        int latencyMs = 200;
        int maxStreams = 16;
    };
    struct Callbacks {
        std::function<void(int port, const std::string& error)> onListening;  // error empty = OK
        std::function<void(const std::string& key, bool connected, const std::string& peer)> onStream;
        std::function<void(const std::string& key, const uint8_t*, size_t, int64_t ptsUs, bool hevc)> onVideo;
        std::function<void(const std::string& key, const DemuxedAudioFrame&)> onAudio;
    };

    SrtIngestServer(Config cfg, Callbacks cb);
    ~SrtIngestServer();
    void start();
    void stop();

    /// "#!::r=live/cam1,m=publish" -> "cam1"; "live/cam1" -> "cam1"; "cam1" -> "cam1".
    static std::string keyFromStreamId(const std::string& sid);

private:
    struct Conn {
        int sock = -1;
        std::string key;
        std::thread th;
        std::atomic<bool> done{false};
    };
    void acceptLoop();
    void serve(Conn* c);
    void reap(bool all);

    Config cfg_;
    Callbacks cb_;
    std::atomic<bool> running_{false};
    std::atomic<int> listener_{-1};
    std::thread acceptTh_;
    std::mutex mtx_;
    std::vector<std::unique_ptr<Conn>> conns_;
};

} // namespace srtkit
