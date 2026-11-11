#include "srtkit/AbrController.h"

#include <algorithm>
#include <cmath>

namespace srtkit {

namespace {
constexpr int kLadderRetryMs[] = {15000, 90000, 300000};
}

AbrController::AbrController(AbrMode mode, int maxBitrateBps, int maxFps, bool variableFps)
    : mode_(mode), maxBitrate_(maxBitrateBps), maxFps_(maxFps), variableFps_(variableFps),
      bitrate_(maxBitrateBps), fps_(maxFps) {}

void AbrController::reset(int64_t nowMs) {
    havePrev_ = false;
    win_.clear();
    bitrate_ = maxBitrate_;
    fps_ = maxFps_;
    logStep_ = 0;
    ladderLevel_ = kLadderLevels - 1;
    ladderRetryIdx_ = 0;
    lastRaiseMs_ = -1;
    lastChangeMs_ = lastDecreaseMs_ = lastRestoreMs_ = nowMs;
}

void AbrController::setMaxBitrate(int bps) {
    double ratio = maxBitrate_ > 0 ? static_cast<double>(bitrate_) / maxBitrate_ : 1.0;
    maxBitrate_ = bps;
    bitrate_ = static_cast<int>(bps * ratio);
}

int AbrController::lossInWindow() const {
    int64_t s = 0;
    for (auto& d : win_) s += d.lost;
    return static_cast<int>(s);
}

int64_t AbrController::sentInWindow() const {
    int64_t s = 0;
    for (auto& d : win_) s += d.sent;
    return s;
}

void AbrController::applyRatio(double r) {
    r = std::clamp(r, kMinRatio, 1.0);
    bitrate_ = static_cast<int>(std::lround(maxBitrate_ * r));
    if (!variableFps_) { fps_ = maxFps_; return; }
    // Variable FPS: >=75% giữ nguyên, >=50% còn 2/3, dưới 50% còn 1/2 (tối thiểu 10 fps)
    int f = maxFps_;
    if (r < 0.5) f = maxFps_ / 2;
    else if (r < 0.75) f = (maxFps_ * 2) / 3;
    fps_ = std::max(std::min(10, maxFps_), f);
}

bool AbrController::onSample(const Sample& s) {
    if (mode_ == AbrMode::Off) return false;
    if (!havePrev_) { prev_ = s; havePrev_ = true; lastChangeMs_ = lastDecreaseMs_ = lastRestoreMs_ = s.nowMs; return false; }

    Delta d{s.nowMs, std::max<int64_t>(0, s.pktSentTotal - prev_.pktSentTotal),
            std::max<int64_t>(0, (s.pktLostTotal - prev_.pktLostTotal) + (s.pktDropTotal - prev_.pktDropTotal))};
    prev_ = s;
    win_.push_back(d);
    while (!win_.empty() && s.nowMs - win_.front().t >= kWindowMs) win_.pop_front();

    const int oldBitrate = bitrate_, oldFps = fps_;
    const int loss = lossInWindow();

    switch (mode_) {
    case AbrMode::LogarithmicDescend: {
        int maxStep = static_cast<int>(std::floor(std::log(kMinRatio) / std::log(kLogStepFactor)));
        if (loss >= kLogLossThreshold && logStep_ < maxStep) {
            ++logStep_;
            applyRatio(std::pow(kLogStepFactor, logStep_));
            lastChangeMs_ = s.nowMs;
            clearWindow();
        } else if (logStep_ > 0 && loss == 0 && s.nowMs - lastChangeMs_ >= kLogRaiseIntervalMs) {
            --logStep_;
            applyRatio(std::pow(kLogStepFactor, logStep_));
            lastChangeMs_ = s.nowMs;
        }
        break;
    }
    case AbrMode::LadderAscend: {
        int threshold = std::max(1, bitrate_ / 300000);
        if (loss >= threshold) {
            // Mất gói ngay sau một lần nâng -> lần sau chờ lâu hơn (15 s -> 90 s -> 300 s)
            if (lastRaiseMs_ >= 0 && s.nowMs - lastRaiseMs_ < kWindowMs * 3)
                ladderRetryIdx_ = std::min(ladderRetryIdx_ + 1, 2);
            ladderLevel_ = 0;  // cắt 2/3 -> còn 1/3
            applyRatio(1.0 / kLadderLevels);
            lastChangeMs_ = s.nowMs;
            lastRaiseMs_ = -1;
            clearWindow();
        } else if (ladderLevel_ < kLadderLevels - 1 && s.nowMs - lastChangeMs_ >= kLadderRetryMs[ladderRetryIdx_]) {
            ++ladderLevel_;
            applyRatio(static_cast<double>(ladderLevel_ + 1) / kLadderLevels);
            lastChangeMs_ = lastRaiseMs_ = s.nowMs;
        } else if (ladderLevel_ == kLadderLevels - 1 && lastRaiseMs_ >= 0 && s.nowMs - lastRaiseMs_ >= 300000) {
            ladderRetryIdx_ = 0;  // ổn định 5 phút ở mức tối đa -> reset chu kỳ thử
            lastRaiseMs_ = -1;
        }
        break;
    }
    case AbrMode::Hybrid: {
        int64_t sent = sentInWindow();
        double lossRatio = sent > 0 ? static_cast<double>(loss) / static_cast<double>(sent) : 0.0;
        if (lossRatio > kHybridLossTrigger && s.nowMs - lastDecreaseMs_ >= kHybridCooldownMs) {
            double delivered = 1.0 - lossRatio;
            double cur = static_cast<double>(bitrate_) / maxBitrate_;
            applyRatio(cur * delivered);
            lastDecreaseMs_ = lastRestoreMs_ = s.nowMs;
            clearWindow();
        } else if (bitrate_ < maxBitrate_ && lossRatio <= kHybridLossTrigger &&
                   s.nowMs - lastRestoreMs_ >= kHybridRestoreMs) {
            double r = static_cast<double>(std::min(maxBitrate_, bitrate_ + kHybridRestoreStepBps)) / maxBitrate_;
            applyRatio(r);
            lastRestoreMs_ = s.nowMs;
        }
        break;
    }
    case AbrMode::Off:
        break;
    }
    return bitrate_ != oldBitrate || fps_ != oldFps;
}

} // namespace srtkit
