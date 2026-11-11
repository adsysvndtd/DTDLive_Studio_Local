// SRTKit – lõi SRT cho app broadcaster (iOS trước, dùng lại được cho Android/desktop)
// Kiểu dữ liệu và cấu hình dùng chung.
#pragma once

#include <cstdint>
#include <functional>
#include <string>
#include <vector>

namespace srtkit {

// ---------------------------------------------------------------------------
// Enum
// ---------------------------------------------------------------------------
enum class SrtMode { Caller, Listener, Rendezvous };

// Nội dung gửi trên mỗi kết nối (Larix: mode = va | a | v)
enum class ContentMode { VideoAudio, AudioOnly, VideoOnly };

// Adaptive bitrate (Larix: 0 off, 1 logarithmic descend, 2 ladder ascend, 3 hybrid)
enum class AbrMode { Off = 0, LogarithmicDescend = 1, LadderAscend = 2, Hybrid = 3 };

enum class VideoCodec { H264, HEVC };
enum class AudioCodec { AAC, Opus };

enum class ConnState {
    Idle,          // chưa start / đã stop
    Connecting,    // đang bắt tay
    Listening,     // listener: đang chờ phía kia kết nối
    Connected,     // đang gửi
    Reconnecting,  // đang chờ để thử lại
    WaitingNetwork,// mất mạng, chờ có mạng lại
    Failed         // hết số lần thử / lỗi cấu hình
};

const char* toString(ConnState s);

// ---------------------------------------------------------------------------
// Cấu hình SRT cho một đích
// ---------------------------------------------------------------------------
struct SrtOptions {
    std::string host;              // caller/rendezvous: địa chỉ đích; listener: địa chỉ bind ("" = 0.0.0.0)
    int port = 0;
    SrtMode mode = SrtMode::Caller;
    int latencyMs = 2000;          // SRTO_LATENCY (Larix: srtlatency)
    int64_t maxBwBytesPerSec = 0;  // 0 = tự động theo input + 25% overhead; >0 = trần cố định; -1 = không giới hạn
    std::string passphrase;        // rỗng = không mã hóa; 10..79 ký tự
    int pbKeyLen = 16;             // 16 | 24 | 32 (AES-128/192/256)
    std::string streamId;          // SRTO_STREAMID
    int connectTimeoutMs = 3000;   // SRTO_CONNTIMEO
    int localPort = 0;             // rendezvous: cổng bind cục bộ (0 = dùng port)
    int payloadSize = 1316;        // 7 x 188
};

// Parse srt://host:port?mode=caller&latency=2000&passphrase=...&pbkeylen=16&streamid=...&maxbw=...
// Trả về false nếu URL sai. err chứa lý do.
bool parseSrtUrl(const std::string& url, SrtOptions& out, std::string* err = nullptr);

// ---------------------------------------------------------------------------
// Chính sách reconnect / timeout (Larix: timeout[reconn], [reconn_no_network], [idle], [unsent])
// ---------------------------------------------------------------------------
struct ReconnectPolicy {
    int reconnectDelayMs = 3000;          // chờ giữa hai lần thử khi có mạng
    int noNetworkReconnectDelayMs = 1000; // chu kỳ kiểm tra lại khi báo mất mạng
    int maxAttempts = 0;                  // 0 = thử vô hạn
    int idleTimeoutMs = 0;                // >0: đã kết nối mà app không đẩy dữ liệu quá N ms -> ngắt, tự nối lại khi có dữ liệu
    int unsentTimeoutMs = 0;              // >0: dữ liệu chưa được ACK quá N ms (msSndBuf) -> coi là treo, nối lại
    bool checkNetwork = true;             // tôn trọng setNetworkAvailable() (Larix: check_network)
};

// ---------------------------------------------------------------------------
// Cấu hình một kết nối (tối đa 5 kết nối song song như Larix max_conn)
// ---------------------------------------------------------------------------
struct ConnectionConfig {
    std::string name;
    SrtOptions srt;
    ContentMode content = ContentMode::VideoAudio;
    AbrMode abr = AbrMode::Off;
    bool variableFps = false;      // Larix adaptiveFps: giảm FPS kèm bitrate
    int queueMs = 1500;            // độ dài tối đa hàng đợi gửi; tràn -> bỏ tới keyframe kế tiếp
};

// ---------------------------------------------------------------------------
// Thông số luồng (giống nhau cho mọi kết nối – một encoder chung)
// ---------------------------------------------------------------------------
struct StreamParams {
    VideoCodec videoCodec = VideoCodec::H264;
    int videoBitrateBps = 2000000;  // bitrate mục tiêu (trần cho ABR)
    int fps = 30;
    int width = 1280, height = 720;

    bool hasAudio = true;
    AudioCodec audioCodec = AudioCodec::AAC;
    int audioSampleRate = 48000;
    int audioChannels = 2;
    int aacProfile = 2;             // 2 = AAC-LC (audioObjectType)

    // Metadata thời gian (Larix: metadata=timeinfo, ntp=host)
    bool insertNtpSei = false;
    std::string ntpHost = "pool.ntp.org";
};

// ---------------------------------------------------------------------------
// Thống kê
// ---------------------------------------------------------------------------
struct ConnectionStats {
    int id = -1;
    std::string name;
    ConnState state = ConnState::Idle;
    int64_t uptimeMs = 0;           // thời gian đã kết nối liên tục
    uint64_t bytesSent = 0;         // tổng byte payload đã gửi (không tính retrans)
    double sendKbps = 0;            // tốc độ gửi tức thời
    double rttMs = 0;
    double bandwidthMbps = 0;       // ước lượng băng thông của SRT
    int64_t pktSent = 0, pktLost = 0, pktRetrans = 0, pktDropped = 0;
    int msSndBuf = 0;               // thời lượng dữ liệu chưa được ACK
    uint64_t framesDropped = 0;     // frame bỏ do tràn hàng đợi / chờ keyframe
    int reconnects = 0;
    int abrBitrateBps = 0;          // bitrate ABR đề xuất cho kết nối này (0 = ABR tắt)
    int abrFps = 0;
    std::string lastError;
};

// ---------------------------------------------------------------------------
// Callback từ lõi về app. Gọi từ thread nội bộ – app tự chuyển về main thread nếu cần.
// ---------------------------------------------------------------------------
struct BroadcasterCallbacks {
    std::function<void(int connId, ConnState state, const std::string& info)> onState;
    std::function<void(const std::vector<ConnectionStats>&)> onStats;   // mỗi giây
    std::function<void(int bitrateBps)> setEncoderBitrate;              // ABR yêu cầu đổi bitrate
    std::function<void(int fps)> setEncoderFps;                         // ABR yêu cầu đổi FPS
    std::function<void()> requestKeyframe;                              // kết nối mới / phục hồi
};

} // namespace srtkit
