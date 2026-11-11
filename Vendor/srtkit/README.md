# SRTKit: lõi SRT (C++) cho app broadcaster iOS

Lõi C++ trên nền **libsrt 1.5.7 + mbedTLS 3.6.7** (mbedTLS lo mã hóa AES). Lõi tái hiện logic SRT của Larix Broadcaster theo tài liệu công khai. Phía Swift gọi qua bridge Objective-C++ (`SRTKit.h`). Phần C++ không phụ thuộc iOS, nên dùng lại được cho Android qua JNI.

## Đối chiếu tính năng với Larix

| Tính năng Larix | SRTKit | Ghi chú |
|---|---|---|
| SRT caller / listener / rendezvous | ✅ | `srtmode` c/l/r |
| latency, maxbw, passphrase, pbkeylen 16/24/32, streamid | ✅ | URL dùng được cả tên kiểu ffmpeg lẫn kiểu Larix Grove (`srtlatency`, `srtpass`, `srtpbkl`…) |
| Tối đa 5 kết nối đồng thời (`max_conn`) | ✅ | mỗi kết nối có thread, hàng đợi và TS muxer riêng |
| Content mode `va` / `a` / `v` cho từng kết nối | ✅ | |
| H.264 / HEVC, AAC / Opus trong MPEG-TS | ✅ | có AUD, PAT/PMT trước mỗi keyframe, PCR, Opus theo ETSI |
| ABR Logarithmic descend | ✅ | ngưỡng 4 gói / 10 s, hạ từng bậc 75%, mỗi 60 s thử nâng lại |
| ABR Ladder ascend | ✅ | ngưỡng bitrate/300000 gói / 10 s, cắt còn 1/3, thử nâng sau 15 s → 90 s → 300 s |
| ABR Hybrid | ✅ | hạ theo tỉ lệ gói giao được, sàn 25%, +500 Kbps mỗi 30 s |
| Variable FPS (`adaptiveFps`) | ✅ | ≥75%: giữ FPS, ≥50%: còn 2/3, dưới 50%: còn 1/2 |
| Nhiều kết nối cùng ABR | ✅ | encoder chạy theo kết nối yếu nhất. Kết nối rớt thì bỏ ràng buộc của nó |
| Reconnect: `reconn`, `reconn_no_network`, `idle`, `unsent`, `check_network` | ✅ | `unsent` phát hiện treo khi không có ACK |
| Pause / Standby / Mute | ✅ (lõi) | giữ kết nối và tạm dừng kiểm tra idle. Khung đen/overlay và PCM câm do compositor làm |
| NTP timecode SEI (`metadata=timeinfo`, `ntp`) | ✅ | SNTP + SEI user_data_unregistered mỗi frame (UUID riêng của SRTKit, xem `Timecode.h`) |
| Talkback qua SRT (pull/listen/rendezvous), AAC/Opus | ✅ | tách TS, bộ đệm phát (`buffer`), trả AudioSpecificConfig |
| Thống kê (bitrate, RTT, mất gói, retrans, drop, uptime, reconnect) | ✅ | mỗi giây |
| Ép keyframe khi kết nối mới hoặc tràn hàng đợi | ✅ | giới hạn 2 lần/giây |

Ngưỡng ABR lấy theo [FAQ Larix](https://softvelum.com/larix/faq/). Các hằng số chi tiết (hệ số bậc, ngưỡng hybrid 2%, quy tắc FPS) là lựa chọn của SRTKit, chỉnh được trong `AbrController.h`.

## Cấu trúc

```
include/srtkit/   API C++ (Types, SrtBroadcaster, SrtConnection, AbrController, TsMuxer, TsDemuxer, Timecode, TalkbackReceiver)
src/              cài đặt
ios/SRTKit.h/.mm  bridge Objective-C++ cho Swift (CMSampleBuffer từ VideoToolbox/AudioConverter)
ios/Example/      StreamController.swift: nối VTCompressionSession + ABR + keyframe
scripts/build-ios.sh  build SRTKit.xcframework (iPhone arm64 + Simulator arm64/x86_64)
tests/            unit test và test end-to-end (Linux/macOS)
```

## Build iOS (trên Mac)

```bash
brew install cmake
./scripts/build-ios.sh          # ra SRTKit.xcframework
```

Kéo `SRTKit.xcframework` vào Xcode, chọn **Do Not Embed**, rồi `import SRTKit` trong Swift. Có thể đặt `IOS_MIN=14.0` để đổi deployment target.

## Dùng từ Swift (rút gọn)

```swift
let p = SRTKStreamParams(); p.videoBitrate = 3_000_000; p.frameRate = 30
let b = SRTKBroadcaster(params: p); b.delegate = self
let c = try SRTKConnectionConfig(url: "srt://ingest.example.vn:9000?latency=2000&passphrase=xxxxxxxxxx&streamid=cam1")
c.abrMode = .ladderAscend; c.variableFrameRate = true
_ = b.addConnection(c)
b.start()
// VTCompressionSession output:
b.appendVideoSampleBuffer(sampleBuffer)
// AAC raw từ AVAudioConverter:
b.appendAudioData(packet, presentationTimeUs: pts)
```

Delegate nhận `requestsVideoBitrate`, `requestsFrameRate` và `broadcasterRequestsKeyframe`, rồi chỉnh VTCompressionSession tương ứng (xem `ios/Example`). Gọi `setNetworkAvailable` từ `NWPathMonitor`.

**Yêu cầu với encoder:** tắt B-frame (`AllowFrameReordering = false`), keyframe interval khoảng 1–2 s, timestamp đơn điệu tăng.

## Test (Linux, đã chạy)

```bash
cmake -S . -B build -DSRT_PREFIX=/path/to/prefix && cmake --build build
./build/test_unit                                   # URL, 3 chế độ ABR, mux/demux AAC+Opus, SEI
./build/test_publish v.h264 a.aac "srt://127.0.0.1:9000?latency=200" 10 [--hevc] [--sei] [--abr 1|2|3] [--vfps] [--content a|v] [--url2 URL] [--unsent ms]
./build/test_talkback a.aac 9010 6
```

Đã kiểm thử với `srt-live-transmit` (libsrt chính chủ) làm đầu nhận. Mọi luồng thu về đều được ffmpeg giải mã không lỗi:

- H.264 + AAC, mã hóa AES-256, streamid, SEI NTP trên từng frame (234/234 frame, cách nhau 33,3 ms)
- HEVC + AAC, SRTKit ở chế độ listener
- Rendezvous
- 2 kết nối song song. Ngắt server chính giữa chừng thì kết nối đó tự nối lại và bắt đầu lại từ keyframe, kết nối dự phòng không gián đoạn
- Audio-only
- ABR Hybrid + Variable FPS khi băng thông bị giới hạn (1.5 Mbps → 738 Kbps/15 fps → 375 Kbps)
- Treo phía nhận (SIGSTOP): sau 2 s không có ACK thì tự nối lại
- Talkback AAC có mã hóa: 234 frame nhận và phát, không frame nào trễ

## Chưa kiểm thử được

- Bridge `SRTKit.mm` và `build-ios.sh` chưa được build vì máy test không có Xcode. Lần build đầu trên Mac có thể cần sửa vài lỗi nhỏ.
- Chưa đo trên thiết bị thật và mạng di động thật. Ngưỡng ABR nên tinh chỉnh theo log thực tế.
