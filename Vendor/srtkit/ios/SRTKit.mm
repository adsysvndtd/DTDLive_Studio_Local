// Bridge Objective-C++ -> lõi C++ SRTKit.
#import "SRTKit.h"

#import <AudioToolbox/AudioToolbox.h>

#include <climits>
#include <memory>
#include <mutex>
#include <vector>

#include "srtkit/SrtBroadcaster.h"
#include "srtkit/TalkbackReceiver.h"
#include "srtkit/WhipClient.h"

using namespace srtkit;

NSString* const SRTKErrorDomain = @"SRTKit";

static NSString* S(const std::string& s) { return [NSString stringWithUTF8String:s.c_str()] ?: @""; }
static std::string C(NSString* _Nullable s) { return s ? std::string(s.UTF8String) : std::string(); }
static int64_t toUs(CMTime t) {
    if (!CMTIME_IS_VALID(t)) return INT64_MIN;
    return CMTimeConvertScale(t, 1000000, kCMTimeRoundingMethod_RoundHalfAwayFromZero).value;
}

// ===========================================================================
@implementation SRTKConnectionConfig

- (instancetype)init {
    if ((self = [super init])) {
        ConnectionConfig c; ReconnectPolicy p;
        _name = @"";
        _host = @"";
        _mode = SRTKModeCaller;
        _latencyMs = c.srt.latencyMs;
        _pbKeyLen = c.srt.pbKeyLen;
        _connectTimeoutMs = c.srt.connectTimeoutMs;
        _content = SRTKContentModeVideoAudio;
        _abrMode = SRTKAbrModeOff;
        _queueMs = c.queueMs;
        _reconnectDelayMs = p.reconnectDelayMs;
        _noNetworkReconnectDelayMs = p.noNetworkReconnectDelayMs;
        _checkNetwork = YES;
    }
    return self;
}

+ (instancetype)configWithURL:(NSString*)url error:(NSError**)error {
    SrtOptions o;
    std::string err;
    if (!parseSrtUrl(C(url), o, &err)) {
        if (error) *error = [NSError errorWithDomain:SRTKErrorDomain code:1 userInfo:@{NSLocalizedDescriptionKey: S(err)}];
        return nil;
    }
    SRTKConnectionConfig* c = [SRTKConnectionConfig new];
    c.host = S(o.host);
    c.port = o.port;
    c.mode = (SRTKMode)o.mode;
    c.latencyMs = o.latencyMs;
    c.passphrase = o.passphrase.empty() ? nil : S(o.passphrase);
    c.pbKeyLen = o.pbKeyLen;
    c.streamId = o.streamId.empty() ? nil : S(o.streamId);
    c.maxBandwidthBytesPerSec = o.maxBwBytesPerSec;
    c.connectTimeoutMs = o.connectTimeoutMs;
    c.localPort = o.localPort;
    return c;
}

- (ConnectionConfig)cpp {
    ConnectionConfig c;
    c.name = C(_name);
    c.srt.host = C(_host);
    c.srt.port = (int)_port;
    c.srt.mode = (SrtMode)_mode;
    c.srt.latencyMs = (int)_latencyMs;
    c.srt.passphrase = C(_passphrase);
    c.srt.pbKeyLen = (int)_pbKeyLen;
    c.srt.streamId = C(_streamId);
    c.srt.maxBwBytesPerSec = _maxBandwidthBytesPerSec;
    c.srt.connectTimeoutMs = (int)_connectTimeoutMs;
    c.srt.localPort = (int)_localPort;
    c.content = (ContentMode)_content;
    c.abr = (AbrMode)_abrMode;
    c.variableFps = _variableFrameRate;
    c.queueMs = (int)_queueMs;
    return c;
}

- (ReconnectPolicy)policy {
    ReconnectPolicy p;
    p.reconnectDelayMs = (int)_reconnectDelayMs;
    p.noNetworkReconnectDelayMs = (int)_noNetworkReconnectDelayMs;
    p.maxAttempts = (int)_maxAttempts;
    p.idleTimeoutMs = (int)_idleTimeoutMs;
    p.unsentTimeoutMs = (int)_unsentTimeoutMs;
    p.checkNetwork = _checkNetwork;
    return p;
}
@end

// ===========================================================================
@implementation SRTKStreamParams
- (instancetype)init {
    if ((self = [super init])) {
        StreamParams p;
        _videoCodec = SRTKVideoCodecH264;
        _videoBitrate = p.videoBitrateBps;
        _frameRate = p.fps;
        _width = p.width;
        _height = p.height;
        _hasAudio = YES;
        _audioCodec = SRTKAudioCodecAAC;
        _audioSampleRate = p.audioSampleRate;
        _audioChannels = p.audioChannels;
        _ntpHost = S(p.ntpHost);
    }
    return self;
}
@end

// ===========================================================================
@interface SRTKConnectionStats ()
- (instancetype)initWithStats:(const ConnectionStats&)s;
@end

@implementation SRTKConnectionStats
- (instancetype)initWithStats:(const ConnectionStats&)s {
    if ((self = [super init])) {
        _connectionId = s.id;
        _name = S(s.name);
        _state = (SRTKConnectionState)s.state;
        _uptime = s.uptimeMs / 1000.0;
        _bytesSent = s.bytesSent;
        _sendKbps = s.sendKbps;
        _rttMs = s.rttMs;
        _bandwidthMbps = s.bandwidthMbps;
        _packetsSent = s.pktSent;
        _packetsLost = s.pktLost;
        _packetsRetransmitted = s.pktRetrans;
        _packetsDropped = s.pktDropped;
        _unackedMs = s.msSndBuf;
        _framesDropped = s.framesDropped;
        _reconnects = s.reconnects;
        _abrBitrate = s.abrBitrateBps;
        _abrFrameRate = s.abrFps;
        _lastError = S(s.lastError);
    }
    return self;
}
@end

// ===========================================================================
@implementation SRTKBroadcaster {
    std::unique_ptr<SrtBroadcaster> _core;
    StreamParams _params;
    CMFormatDescriptionRef _lastFormat;   // để biết khi nào cần lấy lại SPS/PPS
    std::mutex _fmtMtx;
    std::vector<uint8_t> _scratch;
}

- (instancetype)initWithParams:(SRTKStreamParams*)p {
    if ((self = [super init])) {
        _delegateQueue = dispatch_get_main_queue();
        _params.videoCodec = (VideoCodec)p.videoCodec;
        _params.videoBitrateBps = (int)p.videoBitrate;
        _params.fps = (int)p.frameRate;
        _params.width = (int)p.width;
        _params.height = (int)p.height;
        _params.hasAudio = p.hasAudio;
        _params.audioCodec = (srtkit::AudioCodec)p.audioCodec;
        _params.audioSampleRate = (int)p.audioSampleRate;
        _params.audioChannels = (int)p.audioChannels;
        _params.insertNtpSei = p.insertNtpTimecode;
        _params.ntpHost = C(p.ntpHost);

        __weak SRTKBroadcaster* weakSelf = self;
        BroadcasterCallbacks cb;
        cb.onState = [weakSelf](int cid, ConnState s, const std::string& info) {
            NSString* i = S(info);
            SRTKBroadcaster* me = weakSelf;
            if (!me) return;
            dispatch_async(me.delegateQueue, ^{
                SRTKBroadcaster* m = weakSelf;
                id<SRTKBroadcasterDelegate> d = m.delegate;
                if ([d respondsToSelector:@selector(broadcaster:connection:didChangeState:info:)])
                    [d broadcaster:m connection:cid didChangeState:(SRTKConnectionState)s info:i];
            });
        };
        cb.onStats = [weakSelf](const std::vector<ConnectionStats>& v) {
            NSMutableArray* arr = [NSMutableArray arrayWithCapacity:v.size()];
            for (auto& s : v) [arr addObject:[[SRTKConnectionStats alloc] initWithStats:s]];
            SRTKBroadcaster* me = weakSelf;
            if (!me) return;
            dispatch_async(me.delegateQueue, ^{
                SRTKBroadcaster* m = weakSelf;
                id<SRTKBroadcasterDelegate> d = m.delegate;
                if ([d respondsToSelector:@selector(broadcaster:didUpdateStats:)]) [d broadcaster:m didUpdateStats:arr];
            });
        };
        cb.setEncoderBitrate = [weakSelf](int b) {
            SRTKBroadcaster* me = weakSelf;
            if (!me) return;
            dispatch_async(me.delegateQueue, ^{
                SRTKBroadcaster* m = weakSelf;
                id<SRTKBroadcasterDelegate> d = m.delegate;
                if ([d respondsToSelector:@selector(broadcaster:requestsVideoBitrate:)]) [d broadcaster:m requestsVideoBitrate:b];
            });
        };
        cb.setEncoderFps = [weakSelf](int f) {
            SRTKBroadcaster* me = weakSelf;
            if (!me) return;
            dispatch_async(me.delegateQueue, ^{
                SRTKBroadcaster* m = weakSelf;
                id<SRTKBroadcasterDelegate> d = m.delegate;
                if ([d respondsToSelector:@selector(broadcaster:requestsFrameRate:)]) [d broadcaster:m requestsFrameRate:f];
            });
        };
        cb.requestKeyframe = [weakSelf]() {
            SRTKBroadcaster* me = weakSelf;
            if (!me) return;
            dispatch_async(me.delegateQueue, ^{
                SRTKBroadcaster* m = weakSelf;
                id<SRTKBroadcasterDelegate> d = m.delegate;
                if ([d respondsToSelector:@selector(broadcasterRequestsKeyframe:)]) [d broadcasterRequestsKeyframe:m];
            });
        };
        _core = std::make_unique<SrtBroadcaster>(_params, cb);
    }
    return self;
}

- (void)dealloc {
    _core.reset();
    if (_lastFormat) CFRelease(_lastFormat);
}

- (NSInteger)addConnection:(SRTKConnectionConfig*)config { return _core->addConnection([config cpp], [config policy]); }
- (BOOL)removeConnection:(NSInteger)cid { return _core->removeConnection((int)cid); }
- (BOOL)startConnection:(NSInteger)cid { return _core->startConnection((int)cid); }
- (BOOL)stopConnection:(NSInteger)cid { return _core->stopConnection((int)cid); }
- (void)start { _core->start(false); }
- (void)startInStandby { _core->start(true); }
- (void)stop { _core->stop(); }
- (BOOL)isRunning { return _core->isRunning(); }
- (BOOL)isPaused { return _core->paused(); }
- (void)setPaused:(BOOL)paused { _core->setPaused(paused); }
- (void)setNetworkAvailable:(BOOL)available { _core->setNetworkAvailable(available); }
- (void)setTargetBitrate:(NSInteger)bitrate { _core->setTargetBitrate((int)bitrate); }
- (NSInteger)currentBitrate { return _core->currentBitrate(); }
- (NSInteger)currentFrameRate { return _core->currentFps(); }

- (NSArray<SRTKConnectionStats*>*)stats {
    NSMutableArray* arr = [NSMutableArray array];
    for (auto& s : _core->stats()) [arr addObject:[[SRTKConnectionStats alloc] initWithStats:s]];
    return arr;
}

// ---- Video ----
- (void)updateParameterSets:(CMFormatDescriptionRef)fmt nalLengthSize:(int*)nalLen {
    std::vector<std::vector<uint8_t>> sets;
    CMVideoCodecType type = CMFormatDescriptionGetMediaSubType(fmt);
    size_t count = 0;
    int hdr = 4;
    if (type == kCMVideoCodecType_HEVC) {
        if (CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(fmt, 0, nullptr, nullptr, &count, &hdr) != noErr) return;
        for (size_t i = 0; i < count; ++i) {
            const uint8_t* p = nullptr; size_t sz = 0;
            if (CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(fmt, i, &p, &sz, nullptr, nullptr) == noErr)
                sets.emplace_back(p, p + sz);
        }
    } else {
        if (CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, 0, nullptr, nullptr, &count, &hdr) != noErr) return;
        for (size_t i = 0; i < count; ++i) {
            const uint8_t* p = nullptr; size_t sz = 0;
            if (CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, i, &p, &sz, nullptr, nullptr) == noErr)
                sets.emplace_back(p, p + sz);
        }
    }
    *nalLen = hdr;
    _core->setVideoParameterSets(sets);
}

- (void)appendVideoSampleBuffer:(CMSampleBufferRef)sb {
    if (!sb || !CMSampleBufferDataIsReady(sb)) return;
    CMFormatDescriptionRef fmt = CMSampleBufferGetFormatDescription(sb);
    if (!fmt) return;

    bool key = true;
    CFArrayRef att = CMSampleBufferGetSampleAttachmentsArray(sb, false);
    if (att && CFArrayGetCount(att) > 0) {
        CFDictionaryRef d = (CFDictionaryRef)CFArrayGetValueAtIndex(att, 0);
        CFBooleanRef notSync = nullptr;
        if (CFDictionaryGetValueIfPresent(d, kCMSampleAttachmentKey_NotSync, (const void**)&notSync))
            key = !(notSync && CFBooleanGetValue(notSync));
    }

    int nalLen = 4;
    {
        std::lock_guard<std::mutex> l(_fmtMtx);
        if (!_lastFormat || !CFEqual(_lastFormat, fmt) || key) {
            [self updateParameterSets:fmt nalLengthSize:&nalLen];
            if (_lastFormat) CFRelease(_lastFormat);
            _lastFormat = (CMFormatDescriptionRef)CFRetain(fmt);
        }
        CMBlockBufferRef bb = CMSampleBufferGetDataBuffer(sb);
        size_t len = bb ? CMBlockBufferGetDataLength(bb) : 0;
        if (len == 0) return;
        _scratch.resize(len);
        if (CMBlockBufferCopyDataBytes(bb, 0, len, _scratch.data()) != kCMBlockBufferNoErr) return;
        auto annexB = annexb::fromLengthPrefixed(_scratch.data(), len, nalLen);
        int64_t pts = toUs(CMSampleBufferGetPresentationTimeStamp(sb));
        int64_t dts = toUs(CMSampleBufferGetDecodeTimeStamp(sb));
        if (dts == INT64_MIN) dts = pts;
        _core->pushVideo(annexB.data(), annexB.size(), pts, dts, key);
    }
}

- (void)appendVideoAnnexB:(NSData*)data ptsUs:(int64_t)ptsUs dtsUs:(int64_t)dtsUs keyframe:(BOOL)keyframe {
    _core->pushVideo((const uint8_t*)data.bytes, data.length, ptsUs, dtsUs, keyframe);
}

// ---- Audio ----
- (void)appendAudioSampleBuffer:(CMSampleBufferRef)sb {
    if (!sb || !CMSampleBufferDataIsReady(sb)) return;
    CMBlockBufferRef bb = CMSampleBufferGetDataBuffer(sb);
    size_t len = bb ? CMBlockBufferGetDataLength(bb) : 0;
    if (len == 0) return;
    std::vector<uint8_t> buf(len);
    if (CMBlockBufferCopyDataBytes(bb, 0, len, buf.data()) != kCMBlockBufferNoErr) return;

    int64_t pts = toUs(CMSampleBufferGetPresentationTimeStamp(sb));
    const AudioStreamBasicDescription* asbd =
        CMAudioFormatDescriptionGetStreamBasicDescription(CMSampleBufferGetFormatDescription(sb));
    double sr = asbd && asbd->mSampleRate > 0 ? asbd->mSampleRate : _params.audioSampleRate;
    UInt32 framesPerPacket = asbd && asbd->mFramesPerPacket ? asbd->mFramesPerPacket : 1024;

    const AudioStreamPacketDescription* descs = nullptr;
    size_t descBytes = 0;
    CMSampleBufferGetAudioStreamPacketDescriptionsPtr(sb, &descs, &descBytes);
    size_t n = descs ? descBytes / sizeof(AudioStreamPacketDescription) : 0;   // API trả về số BYTE
    if (n > 0) {
        for (size_t i = 0; i < n; ++i) {
            size_t off = (size_t)descs[i].mStartOffset, sz = descs[i].mDataByteSize;
            if (off + sz > len) break;
            int64_t p = pts + (int64_t)(i * framesPerPacket * 1000000.0 / sr);
            _core->pushAudio(buf.data() + off, sz, p);
        }
    } else {
        _core->pushAudio(buf.data(), len, pts);
    }
}

- (void)appendAudioData:(NSData*)data presentationTimeUs:(int64_t)ptsUs {
    _core->pushAudio((const uint8_t*)data.bytes, data.length, ptsUs);
}
@end

// ===========================================================================
@implementation SRTKTalkbackReceiver {
    std::unique_ptr<TalkbackReceiver> _core;
}

- (instancetype)initWithURL:(NSString*)url bufferMs:(NSInteger)bufferMs error:(NSError**)error {
    if ((self = [super init])) {
        TalkbackReceiver::Config cfg;
        std::string err;
        if (!parseSrtUrl(C(url), cfg.srt, &err)) {
            if (error) *error = [NSError errorWithDomain:SRTKErrorDomain code:1 userInfo:@{NSLocalizedDescriptionKey: S(err)}];
            return nil;
        }
        cfg.bufferMs = (int)bufferMs;
        _delegateQueue = dispatch_queue_create("srtkit.talkback", DISPATCH_QUEUE_SERIAL);
        __weak SRTKTalkbackReceiver* weakSelf = self;
        TalkbackReceiver::Callbacks cb;
        cb.onState = [weakSelf](ConnState s, const std::string& info) {
            NSString* i = S(info);
            SRTKTalkbackReceiver* me = weakSelf;
            if (!me) return;
            dispatch_async(me.delegateQueue, ^{
                SRTKTalkbackReceiver* m = weakSelf;
                id<SRTKTalkbackDelegate> d = m.delegate;
                if ([d respondsToSelector:@selector(talkback:didChangeState:info:)])
                    [d talkback:m didChangeState:(SRTKConnectionState)s info:i];
            });
        };
        cb.onAudio = [weakSelf](const DemuxedAudioFrame& f) {
            SRTKTalkbackReceiver* me = weakSelf;
            if (!me) return;
            NSData* data = [NSData dataWithBytes:f.data.data() length:f.data.size()];
            NSData* asc = f.asc.empty() ? nil : [NSData dataWithBytes:f.asc.data() length:f.asc.size()];
            SRTKAudioCodec codec = f.codec == srtkit::AudioCodec::AAC ? SRTKAudioCodecAAC : SRTKAudioCodecOpus;
            NSInteger sr = f.sampleRate, ch = f.channels;
            int64_t pts = f.ptsUs;
            dispatch_async(me.delegateQueue, ^{
                SRTKTalkbackReceiver* m = weakSelf;
                id<SRTKTalkbackDelegate> d = m.delegate;
                if ([d respondsToSelector:@selector(talkback:didReceiveAudio:codec:sampleRate:channels:audioSpecificConfig:ptsUs:)])
                    [d talkback:m didReceiveAudio:data codec:codec sampleRate:sr channels:ch audioSpecificConfig:asc ptsUs:pts];
            });
        };
        _core = std::make_unique<TalkbackReceiver>(cfg, cb);
    }
    return self;
}

- (void)dealloc { _core.reset(); }
- (void)start { _core->start(); }
- (void)stop { _core->stop(); }
@end

// ===========================================================================
@implementation SRTKWhipClient {
    std::unique_ptr<WhipClient> _c;
}

- (instancetype)initWithVideo:(BOOL)video audio:(BOOL)audio profileLevelId:(NSString*)profileLevelId audioChannels:(NSInteger)channels {
    if ((self = [super init])) {
        WhipClient::Options o;
        o.video = video;
        o.audio = audio;
        o.h264ProfileLevelId = C(profileLevelId);
        o.audioChannels = (int)channels;
        _c.reset(new WhipClient(o));
        __weak SRTKWhipClient* ws = self;
        _c->onState = [ws](WhipClient::State st, const std::string& info) {
            SRTKWhipClient* s = ws;
            if (s && s.stateHandler) s.stateHandler((SRTKWhipState)st, S(info));
        };
        _c->onKeyframeRequest = [ws] {
            SRTKWhipClient* s = ws;
            if (s && s.keyframeHandler) s.keyframeHandler();
        };
    }
    return self;
}

- (void)dealloc { _c->stop(); }

- (NSString*)createOffer {
    std::string o = _c->createOffer();
    return o.empty() ? nil : S(o);
}

- (NSString*)setAnswer:(NSString*)sdp {
    std::string e = _c->setAnswer(C(sdp));
    return e.empty() ? nil : S(e);
}

- (BOOL)start { return _c->start(); }
- (void)stop { _c->stop(); }

static std::vector<std::vector<uint8_t>> toVec(NSArray<NSData*>* a) {
    std::vector<std::vector<uint8_t>> v;
    for (NSData* d in a) v.emplace_back((const uint8_t*)d.bytes, (const uint8_t*)d.bytes + d.length);
    return v;
}

- (void)sendVideoAVCC:(NSData*)data ptsUs:(int64_t)ptsUs keyframe:(BOOL)keyframe sps:(NSArray<NSData*>*)sps pps:(NSArray<NSData*>*)pps {
    if (keyframe) _c->sendVideo((const uint8_t*)data.bytes, data.length, ptsUs, true, toVec(sps), toVec(pps));
    else _c->sendVideo((const uint8_t*)data.bytes, data.length, ptsUs, false, {}, {});
}

- (void)sendOpus:(NSData*)data ptsUs:(int64_t)ptsUs { _c->sendOpus((const uint8_t*)data.bytes, data.length, ptsUs); }

- (uint64_t)bytesSent { return _c->stats().bytesSent; }
- (double)rttMs { return _c->stats().rttMs; }
- (double)fractionLost { return _c->stats().fractionLost; }
- (uint64_t)nacksReceived { return _c->stats().nacksReceived; }
- (uint64_t)retransmitted { return _c->stats().retransmitted; }
@end

// ===========================================================================
@implementation SRTKTry
+ (NSString*)run:(NS_NOESCAPE void (^)(void))block {
    @try {
        block();
        return nil;
    } @catch (NSException* e) {
        return [NSString stringWithFormat:@"%@: %@", e.name, e.reason ?: @""];
    }
}
@end
