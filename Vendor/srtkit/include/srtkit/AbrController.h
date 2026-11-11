// Adaptive bitrate cho SRT – 3 chế độ theo mô tả công khai của Larix (FAQ):
//  * Logarithmic descend: ngưỡng 4 gói mất / 10 s gần nhất -> hạ từng bậc;
//    mỗi phút thử nâng lại bậc trước. Hợp mạng tốt.
//  * Ladder ascend: ngưỡng bitrate/300000 gói mất / 10 s -> cắt 2/3 (còn 1/3);
//    thử nâng lại sau 15 s, rồi 1.5 phút, rồi 5 phút. Hợp mạng mất gói nhiều.
//  * Hybrid: đo tỉ lệ gói thực sự giao được, hạ bitrate đúng tỉ lệ đó, tối thiểu 25%;
//    cứ 30 s ổn định thì cộng lại 500 Kbps.
//  * Variable FPS (tùy chọn): hạ FPS kèm theo bitrate.
// Các hằng số chi tiết (hệ số bậc, ngưỡng hybrid) là lựa chọn thiết kế của SRTKit.
#pragma once

#include <cstdint>
#include <deque>

#include "srtkit/Types.h"

namespace srtkit {

class AbrController {
public:
    struct Sample {
        int64_t nowMs;
        int64_t pktSentTotal;     // gói dữ liệu đã gửi (gồm retrans)
        int64_t pktLostTotal;     // gói bị báo mất (NAK) phía gửi
        int64_t pktDropTotal;     // gói bị bỏ vì quá hạn (too-late-to-send)
    };

    AbrController(AbrMode mode, int maxBitrateBps, int maxFps, bool variableFps);

    void reset(int64_t nowMs);
    // Gọi ~1 lần/giây. Trả về true nếu bitrate hoặc fps mục tiêu đổi.
    bool onSample(const Sample& s);

    // Đổi trần (khi người dùng đổi bitrate encoder lúc đang live)
    void setMaxBitrate(int bps);

    int bitrate() const { return bitrate_; }
    int fps() const { return fps_; }
    AbrMode mode() const { return mode_; }

    // Tham số (public để test/tinh chỉnh)
    static constexpr int kWindowMs = 10000;
    static constexpr int kLogLossThreshold = 4;
    static constexpr double kLogStepFactor = 0.75;     // mỗi bậc = 75% bậc trên
    static constexpr double kMinRatio = 0.25;          // sàn 25% trần
    static constexpr int kLogRaiseIntervalMs = 60000;
    static constexpr int kLadderLevels = 3;            // 1/3, 2/3, 3/3
    static constexpr int kHybridRestoreMs = 30000;
    static constexpr int kHybridRestoreStepBps = 500000;
    static constexpr double kHybridLossTrigger = 0.02; // >2% gói mất trong cửa sổ mới hạ
    static constexpr int kHybridCooldownMs = 5000;

private:
    struct Delta { int64_t t; int64_t sent; int64_t lost; };
    int lossInWindow() const;
    int64_t sentInWindow() const;
    void applyRatio(double r);
    void clearWindow() { win_.clear(); }

    AbrMode mode_;
    int maxBitrate_;
    int maxFps_;
    bool variableFps_;
    int bitrate_;
    int fps_;

    bool havePrev_ = false;
    Sample prev_{};
    std::deque<Delta> win_;

    // log descend
    int logStep_ = 0;
    int64_t lastChangeMs_ = 0;
    // ladder
    int ladderLevel_ = kLadderLevels - 1;
    int ladderRetryIdx_ = 0;
    int64_t lastRaiseMs_ = -1;
    // hybrid
    int64_t lastDecreaseMs_ = 0;
    int64_t lastRestoreMs_ = 0;
};

} // namespace srtkit
