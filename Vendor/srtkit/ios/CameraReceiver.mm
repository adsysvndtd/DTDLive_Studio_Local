#import "SRTKit.h"
#import <VideoToolbox/VideoToolbox.h>

#include "srtkit/TalkbackReceiver.h"
#include "srtkit/TsMuxer.h"
#include <atomic>
#include <memory>
#include <arpa/inet.h>

using namespace srtkit;

namespace {
// One complete MPEG-TS video PES per H.264 access unit in the app's muxer.
class CameraDecoder {
public:
    ~CameraDecoder() { reset(); }

    void reset() {
        if (session_) {
            VTDecompressionSessionInvalidate(session_);
            CFRelease(session_);
            session_ = nullptr;
        }
        if (format_) { CFRelease(format_); format_ = nullptr; }
        sps_.clear();
        pps_.clear();
        waitIdr_ = false;
    }

    std::atomic<uint64_t> errors{0};

    void decode(const uint8_t* bytes, size_t count, int64_t pts, void (^onFrame)(CVPixelBufferRef)) {
        // count == 0: the demuxer dropped an access unit with lost packets → skip until the next IDR
        if (count == 0) { waitIdr_ = true; return; }
        auto nals = annexb::split(bytes, count);
        bool idr = false, slice = false, changed = false;
        std::vector<uint8_t> avcc;
        avcc.reserve(count);
        for (const auto& nal : nals) {
            int type = annexb::h264Type(nal);
            if (type == 7 || type == 8) {
                auto& saved = type == 7 ? sps_ : pps_;
                if (saved.size() != nal.size || memcmp(saved.data(), nal.data, nal.size) != 0) {
                    saved.assign(nal.data, nal.data + nal.size);
                    changed = true;
                }
            } else if (type == 1 || type == 5) {
                slice = true;
                idr |= type == 5;
                uint32_t size = htonl(static_cast<uint32_t>(nal.size));
                auto prefix = reinterpret_cast<const uint8_t*>(&size);
                avcc.insert(avcc.end(), prefix, prefix + sizeof(size));
                avcc.insert(avcc.end(), nal.data, nal.data + nal.size);
            }
        }
        if (changed && session_) {
            VTDecompressionSessionInvalidate(session_); CFRelease(session_); session_ = nullptr;
            CFRelease(format_); format_ = nullptr;
        }
        if (!slice || (!session_ && (!idr || !open()))) return;
        // after a loss the following P-frames reference a missing picture: hold the last good frame instead
        if (waitIdr_) { if (!idr) return; waitIdr_ = false; }
        CMBlockBufferRef block = nullptr;
        if (CMBlockBufferCreateWithMemoryBlock(nullptr, nullptr, avcc.size(), nullptr, nullptr, 0,
                                               avcc.size(), 0, &block) != noErr) return;
        CMSampleBufferRef sample = nullptr;
        CMSampleTimingInfo timing = {kCMTimeInvalid, CMTimeMake(pts, 1000000), kCMTimeInvalid};
        size_t size = avcc.size();
        if (CMBlockBufferReplaceDataBytes(avcc.data(), block, 0, size) == noErr &&
            CMSampleBufferCreateReady(nullptr, block, format_, 1, 1, &timing, 1, &size, &sample) == noErr) {
            // Synchronous, no temporal processing: never queue stale preview frames.
            OSStatus status = VTDecompressionSessionDecodeFrameWithOutputHandler(session_, sample, 0, nullptr,
                ^(OSStatus result, VTDecodeInfoFlags, CVImageBufferRef image, CMTime, CMTime) {
                    if (result == noErr && image) onFrame(image);
                });
            if (status != noErr) {
                ++errors;
                // keep the session (no 1 s black/freeze); only a broken session is rebuilt, on the next IDR
                if (status == kVTInvalidSessionErr) reset(); else waitIdr_ = true;
            }
            CFRelease(sample);
        }
        CFRelease(block);
    }

private:
    bool open() {
        if (sps_.empty() || pps_.empty()) return false;
        const uint8_t* params[] = {sps_.data(), pps_.data()};
        size_t sizes[] = {sps_.size(), pps_.size()};
        if (CMVideoFormatDescriptionCreateFromH264ParameterSets(nullptr, 2, params, sizes, 4, &format_) != noErr)
            return false;
        CMVideoDimensions d = CMVideoFormatDescriptionGetDimensions(format_);
        NSDictionary* attrs = @{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
                                (id)kCVPixelBufferIOSurfacePropertiesKey: @{}};
        if (d.width <= 0 || d.height <= 0 || d.width > 4096 || d.height > 4096 ||
            VTDecompressionSessionCreate(nullptr, format_, nullptr, (__bridge CFDictionaryRef)attrs,
                                         nullptr, &session_) != noErr) {
            CFRelease(format_); format_ = nullptr;
            return false;
        }
        return true;
    }
    std::vector<uint8_t> sps_, pps_;
    bool waitIdr_ = false;
    CMVideoFormatDescriptionRef format_ = nullptr;
    VTDecompressionSessionRef session_ = nullptr;
};
}

@implementation SRTKCameraReceiver {
    CameraDecoder _decoder;
    std::atomic<bool> _allowVideo;
    std::unique_ptr<TalkbackReceiver> _receiver;
}
- (instancetype)initWithPassphrase:(NSString*)passphrase onListening:(void (^)(NSInteger))listening
                           onState:(void (^)(SRTKConnectionState, NSString*))state onFrame:(void (^)(CVPixelBufferRef))frame {
    return [self initWithPassphrase:passphrase latencyMs:120 audioBufferMs:0 onListening:listening onState:state onFrame:frame onAudio:nil];
}
- (instancetype)initWithPassphrase:(NSString*)passphrase latencyMs:(NSInteger)latencyMs audioBufferMs:(NSInteger)audioBufferMs
                       onListening:(void (^)(NSInteger))listening
                           onState:(void (^)(SRTKConnectionState, NSString*))state onFrame:(void (^)(CVPixelBufferRef))frame
                           onAudio:(void (^)(NSData*, NSData*, NSInteger, NSInteger, int64_t))audio {
    if ((self = [super init])) {
        _allowVideo = false;
        TalkbackReceiver::Config cfg;
        cfg.srt.mode = SrtMode::Listener;
        cfg.srt.host = "::";
        cfg.srt.port = 0;
        cfg.srt.passphrase = passphrase.UTF8String;
        cfg.srt.pbKeyLen = 16;
        cfg.srt.latencyMs = latencyMs > 0 ? (int)latencyMs : 120;
        cfg.reconnectDelayMs = 500;
        cfg.bufferMs = audioBufferMs > 0 ? (int)audioBufferMs : 100;   // audio jitter buffer ≈ the app's video pacer
        TalkbackReceiver::Callbacks cb;
        cb.onListening = [listening](int port) { listening(port); };
        // The owner joins the receive thread in stop before releasing the receiver.
        CameraDecoder* decoder = &_decoder;
        cb.onState = [decoder, state](ConnState s, const std::string& info) {
            @autoreleasepool {
                decoder->reset();
                state((SRTKConnectionState)s, [NSString stringWithUTF8String:info.c_str()] ?: @"");
            }
        };
        auto approved = &_allowVideo;
        cb.onVideo = [approved, decoder, frame](const uint8_t* bytes, size_t count, int64_t pts) {
            @autoreleasepool {
                if (approved->load()) decoder->decode(bytes, count, pts, frame);
            }
        };
        if (audio) {
            cb.onAudio = [approved, audio](const DemuxedAudioFrame& f) {
                @autoreleasepool {
                    if (!approved->load() || f.codec != AudioCodec::AAC || f.data.empty()) return;
                    audio([NSData dataWithBytes:f.data.data() length:f.data.size()],
                          [NSData dataWithBytes:f.asc.data() length:f.asc.size()],
                          f.sampleRate, f.channels, f.ptsUs);
                }
            };
        }
        _receiver = std::make_unique<TalkbackReceiver>(cfg, std::move(cb));
    }
    return self;
}
- (BOOL)approved { return _allowVideo.load(); }
- (void)setApproved:(BOOL)value { _allowVideo.store(value); }
- (NSDictionary<NSString*, NSNumber*>*)linkStats {
    auto st = _receiver->linkStats();
    return @{@"connected": @(st.connected), @"recv": @(st.pktRecv), @"lost": @(st.pktLoss), @"dropped": @(st.pktDrop),
             @"retrans": @(st.pktRetrans), @"rttMs": @(st.rttMs), @"mbps": @(st.mbpsRecv), @"bandwidthMbps": @(st.mbpsBandwidth),
             @"rcvBufMs": @(st.msRcvBuf), @"latencyMs": @(st.latencyMs), @"ccErrors": @(st.ccErrors),
             @"videoDropped": @(st.videoDropped), @"decodeErrors": @(_decoder.errors.load())};
}
- (void)start { _receiver->start(); }
- (void)stop { _receiver->stop(); }
- (void)dealloc { _receiver.reset(); }
@end
