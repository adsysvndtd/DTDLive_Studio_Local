// DTD Studio: Objective-C bridge for SrtIngestServer — one SRT port, many cameras keyed by streamid.
// Video (H.264 / HEVC) is decoded here with VideoToolbox; AAC is handed to Swift raw with its ASC.
#import "SRTKit.h"
#import <VideoToolbox/VideoToolbox.h>

#include "srtkit/SrtIngestServer.h"
#include "srtkit/TsMuxer.h"
#include <map>
#include <memory>
#include <mutex>
#include <arpa/inet.h>

using namespace srtkit;

namespace {
class IngestDecoder {
public:
    ~IngestDecoder() { reset(); }
    void reset() {
        if (session_) { VTDecompressionSessionInvalidate(session_); CFRelease(session_); session_ = nullptr; }
        if (format_) { CFRelease(format_); format_ = nullptr; }
        params_.clear();
    }
    void decode(const uint8_t* bytes, size_t count, int64_t pts, bool hevc, void (^onFrame)(CVPixelBufferRef)) {
        std::lock_guard<std::mutex> g(m_);
        if (hevc != hevc_) { reset(); hevc_ = hevc; }
        auto nals = annexb::split(bytes, count);
        bool key = false, slice = false;
        std::vector<std::vector<uint8_t>> ps;
        std::vector<uint8_t> avcc; avcc.reserve(count + 16);
        for (const auto& nal : nals) {
            if (!nal.size) continue;
            int t = hevc ? annexb::hevcType(nal) : annexb::h264Type(nal);
            bool isPS = hevc ? (t == 32 || t == 33 || t == 34) : (t == 7 || t == 8);
            bool isSlice = hevc ? (t <= 31) : (t == 1 || t == 5);
            bool isKey = hevc ? (t >= 16 && t <= 23) : (t == 5);
            if (isPS) { ps.emplace_back(nal.data, nal.data + nal.size); continue; }
            if (!isSlice) continue;
            slice = true; key |= isKey;
            uint32_t sz = htonl(static_cast<uint32_t>(nal.size));
            auto p = reinterpret_cast<const uint8_t*>(&sz);
            avcc.insert(avcc.end(), p, p + 4);
            avcc.insert(avcc.end(), nal.data, nal.data + nal.size);
        }
        if (ps.size() >= (hevc ? 3u : 2u) && ps != params_) {
            if (session_) { VTDecompressionSessionInvalidate(session_); CFRelease(session_); session_ = nullptr; }
            if (format_) { CFRelease(format_); format_ = nullptr; }
            params_ = ps;
        }
        if (!slice || (!session_ && (!key || !open()))) return;
        CMBlockBufferRef block = nullptr;
        if (CMBlockBufferCreateWithMemoryBlock(nullptr, nullptr, avcc.size(), nullptr, nullptr, 0, avcc.size(), 0, &block) != noErr) return;
        CMSampleBufferRef sample = nullptr;
        CMSampleTimingInfo timing = {kCMTimeInvalid, CMTimeMake(pts, 1000000), kCMTimeInvalid};
        size_t size = avcc.size();
        if (CMBlockBufferReplaceDataBytes(avcc.data(), block, 0, size) == noErr &&
            CMSampleBufferCreateReady(nullptr, block, format_, 1, 1, &timing, 1, &size, &sample) == noErr) {
            OSStatus st = VTDecompressionSessionDecodeFrameWithOutputHandler(session_, sample, 0, nullptr,
                ^(OSStatus result, VTDecodeInfoFlags, CVImageBufferRef image, CMTime, CMTime) {
                    if (result == noErr && image) onFrame(image);
                });
            if (st != noErr) { VTDecompressionSessionInvalidate(session_); CFRelease(session_); session_ = nullptr; }
            CFRelease(sample);
        }
        CFRelease(block);
    }
private:
    bool open() {
        if (params_.size() < (hevc_ ? 3u : 2u)) return false;
        if (!format_) {
            std::vector<const uint8_t*> ptrs; std::vector<size_t> sizes;
            // keep the canonical order: (VPS,) SPS, PPS
            std::vector<std::vector<uint8_t>> ordered;
            for (int want : (hevc_ ? std::vector<int>{32, 33, 34} : std::vector<int>{7, 8}))
                for (auto& p : params_) {
                    annexb::Nal n{p.data(), p.size()};
                    if ((hevc_ ? annexb::hevcType(n) : annexb::h264Type(n)) == want) { ordered.push_back(p); break; }
                }
            if (ordered.size() < (hevc_ ? 3u : 2u)) return false;
            for (auto& p : ordered) { ptrs.push_back(p.data()); sizes.push_back(p.size()); }
            OSStatus st = hevc_
                ? CMVideoFormatDescriptionCreateFromHEVCParameterSets(nullptr, ptrs.size(), ptrs.data(), sizes.data(), 4, nullptr, &format_)
                : CMVideoFormatDescriptionCreateFromH264ParameterSets(nullptr, ptrs.size(), ptrs.data(), sizes.data(), 4, &format_);
            if (st != noErr) { format_ = nullptr; return false; }
        }
        CMVideoDimensions d = CMVideoFormatDescriptionGetDimensions(format_);
        NSDictionary* attrs = @{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
                                (id)kCVPixelBufferIOSurfacePropertiesKey: @{}};
        if (d.width <= 0 || d.height <= 0 || d.width > 8192 || d.height > 8192 ||
            VTDecompressionSessionCreate(nullptr, format_, nullptr, (__bridge CFDictionaryRef)attrs, nullptr, &session_) != noErr) {
            CFRelease(format_); format_ = nullptr; return false;
        }
        return true;
    }
    std::mutex m_;
    bool hevc_ = false;
    std::vector<std::vector<uint8_t>> params_;
    CMVideoFormatDescriptionRef format_ = nullptr;
    VTDecompressionSessionRef session_ = nullptr;
};
}

@implementation SRTKIngestServer {
    std::unique_ptr<SrtIngestServer> _server;
    std::mutex _mapLock;
    std::map<std::string, std::shared_ptr<IngestDecoder>> _decoders;
}

- (instancetype)initWithPort:(NSInteger)port passphrase:(NSString*)passphrase latencyMs:(NSInteger)latency
                 onListening:(void (^)(NSInteger, NSString*))listening
                    onStream:(void (^)(NSString*, BOOL, NSString*))stream
                     onFrame:(void (^)(NSString*, CVPixelBufferRef))frame
                     onAudio:(void (^)(NSString*, NSData*, NSData*, NSInteger, NSInteger, int64_t))audio {
    if ((self = [super init])) {
        SrtIngestServer::Config cfg;
        cfg.port = (int)port;
        cfg.passphrase = passphrase.length >= 10 ? passphrase.UTF8String : "";
        cfg.latencyMs = (int)latency;
        SrtIngestServer::Callbacks cb;
        cb.onListening = [listening](int p, const std::string& err) {
            @autoreleasepool { listening(p, [NSString stringWithUTF8String:err.c_str()] ?: @""); }
        };
        __unsafe_unretained SRTKIngestServer* weakSelf = self;   // server is stopped/joined in -stop before dealloc
        cb.onStream = [weakSelf, stream](const std::string& key, bool connected, const std::string& peer) {
            @autoreleasepool {
                {
                    std::lock_guard<std::mutex> g(weakSelf->_mapLock);
                    if (connected) weakSelf->_decoders[key] = std::make_shared<IngestDecoder>();
                    else weakSelf->_decoders.erase(key);
                }
                stream([NSString stringWithUTF8String:key.c_str()] ?: @"", connected, [NSString stringWithUTF8String:peer.c_str()] ?: @"");
            }
        };
        cb.onVideo = [weakSelf, frame](const std::string& key, const uint8_t* b, size_t n, int64_t pts, bool hevc) {
            @autoreleasepool {
                std::shared_ptr<IngestDecoder> d;
                {
                    std::lock_guard<std::mutex> g(weakSelf->_mapLock);
                    auto it = weakSelf->_decoders.find(key);
                    if (it != weakSelf->_decoders.end()) d = it->second;
                }
                if (!d) return;
                NSString* k = [NSString stringWithUTF8String:key.c_str()] ?: @"";
                d->decode(b, n, pts, hevc, ^(CVPixelBufferRef image) { frame(k, image); });
            }
        };
        cb.onAudio = [audio](const std::string& key, const DemuxedAudioFrame& f) {
            @autoreleasepool {
                if (f.codec != AudioCodec::AAC || f.data.empty()) return;
                audio([NSString stringWithUTF8String:key.c_str()] ?: @"",
                      [NSData dataWithBytes:f.data.data() length:f.data.size()],
                      [NSData dataWithBytes:f.asc.data() length:f.asc.size()],
                      f.sampleRate, f.channels, f.ptsUs);
            }
        };
        _server = std::make_unique<SrtIngestServer>(cfg, std::move(cb));
    }
    return self;
}
- (void)start { _server->start(); }
- (void)stop { _server->stop(); }
- (void)dealloc { _server.reset(); }
+ (NSString*)keyFromStreamId:(NSString*)sid {
    return [NSString stringWithUTF8String:SrtIngestServer::keyFromStreamId(sid.UTF8String).c_str()] ?: @"";
}
@end
