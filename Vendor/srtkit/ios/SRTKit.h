// SRTKit – API Objective-C (dùng trực tiếp từ Swift) cho lõi SRT C++.
//
// Luồng dùng điển hình:
//   VTCompressionSession  -> appendVideoSampleBuffer:
//   AudioConverter (AAC)  -> appendAudioSampleBuffer: hoặc appendAudioData:presentationTimeUs:
//   Delegate nhận yêu cầu đổi bitrate/FPS (ABR) và yêu cầu keyframe -> chỉnh VTCompressionSession.
#import <CoreMedia/CoreMedia.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
typedef NS_ENUM(NSInteger,SRTKPairEvent) {
    SRTKPairEventListening, SRTKPairEventVerify, SRTKPairEventAuthorized, SRTKPairEventAccepted, SRTKPairEventEnded
};
typedef void (^SRTKPairHandler)(SRTKPairEvent event, NSString* request, NSString* peer, NSString* value, NSInteger port);
@interface SRTKCameraPair : NSObject
- (instancetype)initWithHandler:(SRTKPairHandler)handler NS_SWIFT_NAME(init(handler:));
- (void)listenWithBond:(NSString*)bond NS_SWIFT_NAME(listen(bond:));
- (void)connectHost:(NSString*)host port:(NSInteger)port name:(NSString*)name bond:(NSString*)bond NS_SWIFT_NAME(connect(host:port:name:bond:));
- (void)decide:(NSString*)request allow:(BOOL)allow NS_SWIFT_NAME(decide(_:allow:));
- (void)mediaReady:(NSString*)request port:(NSInteger)port NS_SWIFT_NAME(mediaReady(_:port:));
- (void)stop;
@end



typedef NS_ENUM(NSInteger, SRTKConnectionState) {
    SRTKConnectionStateIdle = 0,
    SRTKConnectionStateConnecting,
    SRTKConnectionStateListening,
    SRTKConnectionStateConnected,
    SRTKConnectionStateReconnecting,
    SRTKConnectionStateWaitingNetwork,
    SRTKConnectionStateFailed,
};

typedef NS_ENUM(NSInteger, SRTKMode) { SRTKModeCaller = 0, SRTKModeListener, SRTKModeRendezvous };
typedef NS_ENUM(NSInteger, SRTKContentMode) { SRTKContentModeVideoAudio = 0, SRTKContentModeAudioOnly, SRTKContentModeVideoOnly };
typedef NS_ENUM(NSInteger, SRTKAbrMode) {
    SRTKAbrModeOff = 0,
    SRTKAbrModeLogarithmicDescend = 1,
    SRTKAbrModeLadderAscend = 2,
    SRTKAbrModeHybrid = 3,
};
typedef NS_ENUM(NSInteger, SRTKVideoCodec) { SRTKVideoCodecH264 = 0, SRTKVideoCodecHEVC };
typedef NS_ENUM(NSInteger, SRTKAudioCodec) { SRTKAudioCodecAAC = 0, SRTKAudioCodecOpus };

FOUNDATION_EXPORT NSString* const SRTKErrorDomain;

// ---------------------------------------------------------------------------
@interface SRTKConnectionConfig : NSObject
/// srt://host:port?mode=caller|listener|rendezvous&latency=&passphrase=&pbkeylen=&streamid=&maxbw=&localport=
+ (nullable instancetype)configWithURL:(NSString*)url error:(NSError**)error NS_SWIFT_NAME(init(url:));

@property (nonatomic, copy) NSString* name;
@property (nonatomic, copy) NSString* host;
@property (nonatomic) NSInteger port;
@property (nonatomic) SRTKMode mode;
@property (nonatomic) NSInteger latencyMs;              // mặc định 2000
@property (nonatomic, copy, nullable) NSString* passphrase;
@property (nonatomic) NSInteger pbKeyLen;               // 16/24/32
@property (nonatomic, copy, nullable) NSString* streamId;
@property (nonatomic) int64_t maxBandwidthBytesPerSec;  // 0 tự động, -1 không giới hạn
@property (nonatomic) NSInteger connectTimeoutMs;
@property (nonatomic) NSInteger localPort;              // rendezvous

@property (nonatomic) SRTKContentMode content;
@property (nonatomic) SRTKAbrMode abrMode;
@property (nonatomic) BOOL variableFrameRate;
@property (nonatomic) NSInteger queueMs;                // mặc định 1500

// Reconnect / timeout
@property (nonatomic) NSInteger reconnectDelayMs;       // 3000
@property (nonatomic) NSInteger noNetworkReconnectDelayMs; // 1000
@property (nonatomic) NSInteger maxAttempts;            // 0 = vô hạn
@property (nonatomic) NSInteger idleTimeoutMs;          // 0 = tắt
@property (nonatomic) NSInteger unsentTimeoutMs;        // 0 = tắt
@property (nonatomic) BOOL checkNetwork;                // YES
@end

// ---------------------------------------------------------------------------
@interface SRTKStreamParams : NSObject
@property (nonatomic) SRTKVideoCodec videoCodec;
@property (nonatomic) NSInteger videoBitrate;           // bps – trần cho ABR
@property (nonatomic) NSInteger frameRate;
@property (nonatomic) NSInteger width;
@property (nonatomic) NSInteger height;
@property (nonatomic) BOOL hasAudio;
@property (nonatomic) SRTKAudioCodec audioCodec;
@property (nonatomic) NSInteger audioSampleRate;
@property (nonatomic) NSInteger audioChannels;
@property (nonatomic) BOOL insertNtpTimecode;           // SEI NTP mỗi frame
@property (nonatomic, copy) NSString* ntpHost;
@end

// ---------------------------------------------------------------------------
@interface SRTKConnectionStats : NSObject
@property (nonatomic, readonly) NSInteger connectionId;
@property (nonatomic, readonly, copy) NSString* name;
@property (nonatomic, readonly) SRTKConnectionState state;
@property (nonatomic, readonly) NSTimeInterval uptime;
@property (nonatomic, readonly) uint64_t bytesSent;
@property (nonatomic, readonly) double sendKbps;
@property (nonatomic, readonly) double rttMs;
@property (nonatomic, readonly) double bandwidthMbps;
@property (nonatomic, readonly) int64_t packetsSent, packetsLost, packetsRetransmitted, packetsDropped;
@property (nonatomic, readonly) NSInteger unackedMs;
@property (nonatomic, readonly) uint64_t framesDropped;
@property (nonatomic, readonly) NSInteger reconnects;
@property (nonatomic, readonly) NSInteger abrBitrate;
@property (nonatomic, readonly) NSInteger abrFrameRate;
@property (nonatomic, readonly, copy) NSString* lastError;
@end

@class SRTKBroadcaster;

@protocol SRTKBroadcasterDelegate <NSObject>
@optional
- (void)broadcaster:(SRTKBroadcaster*)broadcaster connection:(NSInteger)connectionId
     didChangeState:(SRTKConnectionState)state info:(NSString*)info
    NS_SWIFT_NAME(broadcaster(_:connection:didChangeState:info:));
- (void)broadcaster:(SRTKBroadcaster*)broadcaster didUpdateStats:(NSArray<SRTKConnectionStats*>*)stats
    NS_SWIFT_NAME(broadcaster(_:didUpdateStats:));
/// ABR: đặt kVTCompressionPropertyKey_AverageBitRate + DataRateLimits
- (void)broadcaster:(SRTKBroadcaster*)broadcaster requestsVideoBitrate:(NSInteger)bitrate
    NS_SWIFT_NAME(broadcaster(_:requestsVideoBitrate:));
/// Variable FPS: đặt kVTCompressionPropertyKey_ExpectedFrameRate và giảm nhịp đưa khung
- (void)broadcaster:(SRTKBroadcaster*)broadcaster requestsFrameRate:(NSInteger)fps
    NS_SWIFT_NAME(broadcaster(_:requestsFrameRate:));
/// Kết nối mới / phục hồi: encode frame kế tiếp với kVTEncodeFrameOptionKey_ForceKeyFrame
- (void)broadcasterRequestsKeyframe:(SRTKBroadcaster*)broadcaster NS_SWIFT_NAME(broadcasterRequestsKeyframe(_:));
@end

// ---------------------------------------------------------------------------
@interface SRTKBroadcaster : NSObject

- (instancetype)initWithParams:(SRTKStreamParams*)params NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@property (nonatomic, weak, nullable) id<SRTKBroadcasterDelegate> delegate;
@property (nonatomic, strong) dispatch_queue_t delegateQueue;   // mặc định main queue

/// Tối đa 5 kết nối. Trả về id (>0) hoặc -1.
- (NSInteger)addConnection:(SRTKConnectionConfig*)config;
- (BOOL)removeConnection:(NSInteger)connectionId;
- (BOOL)startConnection:(NSInteger)connectionId;
- (BOOL)stopConnection:(NSInteger)connectionId;

- (void)start;
/// Bắt đầu ở Standby: kết nối ngay nhưng ở trạng thái Pause.
- (void)startInStandby;
- (void)stop;
@property (nonatomic, readonly, getter=isRunning) BOOL running;

/// Pause/Standby: giữ kết nối. App phải đưa khung đen/overlay và PCM câm (nếu "Mute audio" bật).
@property (nonatomic, getter=isPaused) BOOL paused;

/// Gọi từ NWPathMonitor.
- (void)setNetworkAvailable:(BOOL)available;
/// Người dùng đổi bitrate khi đang live.
- (void)setTargetBitrate:(NSInteger)bitrate;

/// Output của VTCompressionSession (AVCC/HVCC). Tự lấy SPS/PPS/VPS từ format description.
- (void)appendVideoSampleBuffer:(CMSampleBufferRef)sampleBuffer;
/// Video Annex-B có sẵn (đầy đủ start code).
- (void)appendVideoAnnexB:(NSData*)data ptsUs:(int64_t)ptsUs dtsUs:(int64_t)dtsUs keyframe:(BOOL)keyframe;
/// Audio đã encode (AAC hoặc Opus) dạng CMSampleBuffer, có thể nhiều packet.
- (void)appendAudioSampleBuffer:(CMSampleBufferRef)sampleBuffer;
/// Một access unit AAC raw (không ADTS) hoặc một gói Opus.
- (void)appendAudioData:(NSData*)data presentationTimeUs:(int64_t)ptsUs NS_SWIFT_NAME(appendAudioData(_:presentationTimeUs:));

- (NSArray<SRTKConnectionStats*>*)stats NS_SWIFT_NAME(currentStats());
@property (nonatomic, readonly) NSInteger currentBitrate;
@property (nonatomic, readonly) NSInteger currentFrameRate;
@end

// ---------------------------------------------------------------------------
/// Encrypted, video-only SRT input for a paired LAN camera. Callbacks run on the receive thread.
@interface SRTKCameraReceiver : NSObject
- (instancetype)initWithPassphrase:(NSString*)passphrase
                       onListening:(void (^)(NSInteger port))listening
                           onState:(void (^)(SRTKConnectionState state, NSString* detail))state
                           onFrame:(void (^)(CVPixelBufferRef frame))frame
    NS_SWIFT_NAME(init(passphrase:onListening:onState:onFrame:));
- (instancetype)init NS_UNAVAILABLE;
@property (atomic) BOOL approved;
- (void)start;
- (void)stop;
@end

// ---------------------------------------------------------------------------
/// DTD Studio: SRT ingest server — one listener port, many callers identified by streamid
/// (MPEG-TS, H.264 / HEVC + AAC). Callbacks run on SRT worker threads.
@interface SRTKIngestServer : NSObject
- (instancetype)initWithPort:(NSInteger)port
                  passphrase:(NSString*)passphrase
                   latencyMs:(NSInteger)latency
                 onListening:(void (^)(NSInteger port, NSString* error))listening
                    onStream:(void (^)(NSString* key, BOOL connected, NSString* peer))stream
                     onFrame:(void (^)(NSString* key, CVPixelBufferRef frame))frame
                     onAudio:(void (^)(NSString* key, NSData* aac, NSData* asc, NSInteger sampleRate, NSInteger channels, int64_t ptsUs))audio
    NS_SWIFT_NAME(init(port:passphrase:latencyMs:onListening:onStream:onFrame:onAudio:));
- (instancetype)init NS_UNAVAILABLE;
- (void)start;
- (void)stop;
+ (NSString*)keyFromStreamId:(NSString*)sid;
@end

@class SRTKTalkbackReceiver;

@protocol SRTKTalkbackDelegate <NSObject>
@optional
- (void)talkback:(SRTKTalkbackReceiver*)talkback didChangeState:(SRTKConnectionState)state info:(NSString*)info
    NS_SWIFT_NAME(talkback(_:didChangeState:info:));
/// Gọi đúng nhịp phát (đã qua bộ đệm). AAC: data là raw AU, audioSpecificConfig để tạo AudioConverter.
- (void)talkback:(SRTKTalkbackReceiver*)talkback
 didReceiveAudio:(NSData*)data
           codec:(SRTKAudioCodec)codec
      sampleRate:(NSInteger)sampleRate
        channels:(NSInteger)channels
audioSpecificConfig:(nullable NSData*)asc
      ptsUs:(int64_t)ptsUs
    NS_SWIFT_NAME(talkback(_:didReceiveAudio:codec:sampleRate:channels:audioSpecificConfig:ptsUs:));
@end

@interface SRTKTalkbackReceiver : NSObject
/// srt://host:port?mode=caller (pull) | listener | rendezvous ...
- (nullable instancetype)initWithURL:(NSString*)url bufferMs:(NSInteger)bufferMs error:(NSError**)error
    NS_SWIFT_NAME(init(url:bufferMs:));
- (instancetype)init NS_UNAVAILABLE;
@property (nonatomic, weak, nullable) id<SRTKTalkbackDelegate> delegate;
@property (nonatomic, strong) dispatch_queue_t delegateQueue;   // mặc định: queue riêng (serial), không phải main
- (void)start;
- (void)stop;
@end

// ---------------------------------------------------------------------------
// WHIP (WebRTC): ICE + DTLS-SRTP + RTP H.264/Opus. Phần HTTP (POST/DELETE) do app làm.
typedef NS_ENUM(NSInteger, SRTKWhipState) {
    SRTKWhipStateIdle = 0,
    SRTKWhipStateChecking,
    SRTKWhipStateHandshaking,
    SRTKWhipStateConnected,
    SRTKWhipStateFailed,
    SRTKWhipStateClosed,
};

@interface SRTKWhipClient : NSObject
- (instancetype)initWithVideo:(BOOL)video audio:(BOOL)audio profileLevelId:(NSString*)profileLevelId
                audioChannels:(NSInteger)channels NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
/// SDP offer; nil nếu không tạo được chứng chỉ DTLS
- (nullable NSString*)createOffer;
/// nil nếu answer hợp lệ, ngược lại là thông báo lỗi
- (nullable NSString*)setAnswer:(NSString*)sdp;
- (BOOL)start;
/// Chặn tới khi luồng nội bộ dừng – không gọi từ trong stateHandler
- (void)stop;
- (void)sendVideoAVCC:(NSData*)data ptsUs:(int64_t)ptsUs keyframe:(BOOL)keyframe
                  sps:(NSArray<NSData*>*)sps pps:(NSArray<NSData*>*)pps;
- (void)sendOpus:(NSData*)data ptsUs:(int64_t)ptsUs;
/// Gọi trên luồng nội bộ
@property (nonatomic, copy, nullable) void (^stateHandler)(SRTKWhipState state, NSString* info);
@property (nonatomic, copy, nullable) void (^keyframeHandler)(void);
@property (nonatomic, readonly) uint64_t bytesSent;
@property (nonatomic, readonly) double rttMs;
@property (nonatomic, readonly) double fractionLost;
@property (nonatomic, readonly) uint64_t nacksReceived;
@property (nonatomic, readonly) uint64_t retransmitted;
@end

// ---------------------------------------------------------------------------
/// Chạy một khối và bắt NSException (AVFoundation ném ngoại lệ ObjC khi đặt thuộc tính không hỗ trợ;
/// Swift không bắt được nên app sẽ crash). Trả về mô tả lỗi, nil nếu chạy bình thường.
@interface SRTKTry : NSObject
+ (nullable NSString*)run:(NS_NOESCAPE void (^)(void))block;
@end

NS_ASSUME_NONNULL_END
