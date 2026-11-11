// NTP timecode: lấy giờ NTP (SNTP) và tạo SEI user_data_unregistered chứa timestamp
// để phía nhận đồng bộ nhiều camera (tương đương Larix "metadata = timeinfo").
#pragma once

#include <atomic>
#include <cstdint>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "srtkit/Types.h"

namespace srtkit {

// UUID của SEI do SRTKit định nghĩa. Payload sau UUID:
//   8 byte NTP timestamp (giây 32 bit + phần lẻ 32 bit, big-endian) của thời điểm capture.
extern const uint8_t kSrtKitTimecodeUuid[16];

class NtpClock {
public:
    NtpClock() = default;
    ~NtpClock();

    // Bắt đầu đồng bộ nền với host (cổng 123). Lặp lại mỗi refreshSec giây.
    void start(const std::string& host, int refreshSec = 600);
    void stop();

    // Giờ NTP hiện tại tính bằng micro giây kể từ 1970 (system clock + offset đo được).
    int64_t nowUnixUs() const;
    bool synced() const { return synced_.load(); }
    int64_t offsetUs() const { return offsetUs_.load(); }

    // Đo một lần (đồng bộ, timeout ms). Trả về true nếu đo được.
    static bool query(const std::string& host, int timeoutMs, int64_t& offsetUs, int64_t& rttUs);

private:
    std::atomic<int64_t> offsetUs_{0};
    std::atomic<bool> synced_{false};
    std::atomic<bool> running_{false};
    std::thread th_;
    std::mutex m_;
};

// Tạo NAL SEI (có header, đã thêm emulation prevention) chứa unixUs.
std::vector<uint8_t> buildTimecodeSei(VideoCodec codec, int64_t unixUs);

// Đọc lại SEI (dùng cho kiểm thử / phía nhận). Trả về true nếu là SEI timecode của SRTKit.
bool parseTimecodeSei(VideoCodec codec, const uint8_t* nal, size_t len, int64_t& unixUs);

} // namespace srtkit
