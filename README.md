# DTD Studio: bàn trộn hình nhiều camera và livestream cho iPad/iPhone

Đây là app viết mới hoàn toàn bằng Swift, không dùng lại mã của TopDirector. Bản TopDirector 1.9.8 cài trên máy chỉ được dùng để tham khảo kiến trúc (xem `docs/ANALYSIS.md`).

## Tính năng

| Nhóm | Có trong bản này |
|---|---|
| Nguồn vào | Camera trong máy, camera UVC/HDMI→USB (iPadOS 17+), SRT (caller/listener), RTMP play, file video lặp |
| Bàn trộn | Hai bus PREVIEW/PROGRAM; CUT (phím Space), AUTO (phím Return); hiệu ứng MIX/WIPE/DIP với thời lượng chỉnh được; FTB; chạm 1 lần chọn preview, chạm 2 lần lên thẳng program |
| Lớp phủ | Logo PNG, PiP từ bất kỳ nguồn nào |
| Âm thanh | Mic/USB audio, có đồng hồ mức tiếng |
| **Đầu ra (mới)** | **Push RTMP/RTMPS, push SRT (caller/listener/rendezvous, passphrase, latency), push RTSP (ANNOUNCE/RECORD)**, ghi MP4. Nhiều đích chạy song song |
| Khung hình | 1920×1080 ngang hoặc 1080×1920 dọc |

## Kiến trúc

```
Sources (Camera/SRT/RTMP/File) ─▶ FrameStore (frame-sync)
                                     │
                    Switcher (CoreImage + Metal, đồng hồ 30 fps cố định)
                     │ PGM/PVW monitor          │ CVPixelBuffer (NV12, BT.709)
                     ▼                          ▼
                 MonitorView         VideoEncoder (VideoToolbox H.264, 1 lần)
AudioCapture ─▶ AudioEncoder (AAC 1 lần) ──┐    │
                                           ▼    ▼
                            OutputManager (fan-out, mỗi đích 1 hàng đợi riêng)
                      ┌──────────┬───────────┬───────────┬──────────┐
                  RTMPOutput  SRTOutput  RTSPOutput  RecordOutput
                (HaishinKit) (HaishinKit) (RTSPPush)  (AVAssetWriter)
```

- **Encode một lần, gửi ra nhiều đích.** Có 3 đích thì vẫn chỉ tốn 1 phiên encoder phần cứng.
- **Mỗi đích có hàng đợi riêng, giữ đúng thứ tự gói.** Đích nào chậm thì chỉ đích đó bỏ frame rồi đồng bộ lại ở IDR kế tiếp, các đích khác không bị ảnh hưởng.
- **Tự kết nối lại** với backoff tăng dần 1→30 giây. Sau mỗi lần kết nối lại, app xin IDR và chỉ gửi video bắt đầu từ keyframe.
- **Chung một đồng hồ** (mach host time) cho camera, AVAudioEngine và timestamp RTMP, nên âm thanh và hình khớp nhau.
- **Không dùng B-frame** (`AllowFrameReordering=false`), nên PTS = DTS. Cách này đơn giản và an toàn cho cả RTMP, TS và RTP.

### Cách nhập URL cho đầu ra

| Giao thức | Ví dụ |
|---|---|
| RTMP | `rtmp://a.rtmp.youtube.com/live2/<stream-key>`, `rtmps://live-api-s.facebook.com:443/rtmp/<key>` |
| SRT | `srt://host:9000?mode=caller&streamid=publish:live/cam&latency=200000&passphrase=xxxxxxxxxx` |
| RTSP | `rtsp://user:pass@host:8554/live/cam` (hỗ trợ Basic/Digest; RTP chạy interleaved trên TCP nên đi qua NAT được) |

> Tham số `latency` của SRT trong HaishinKit tính bằng **micro giây**. Ví dụ: 200000 = 200 ms.

## Build

Cần macOS có Xcode 16 trở lên.

```bash
brew install xcodegen
cd DTDStudio
xcodegen generate
open DTDStudio.xcodeproj      # chọn Team, chạy trên iPad thật (simulator không có encoder/camera)

# Unit test cho module RTSP (packetizer RTP, SDP, Digest auth, parser):
cd Packages/RTSPPush && swift test
```

Thử nhanh đầu ra RTSP và SRT bằng MediaMTX:

```bash
docker run --rm -p 8554:8554 -p 8890:8890/udp bluenviron/mediamtx
# RTSP push:  rtsp://<mac-ip>:8554/test
# SRT push:   srt://<mac-ip>:8890?mode=caller&streamid=publish:test
ffplay rtsp://<mac-ip>:8554/test
```

## Trạng thái và việc tiếp theo

- Mã **chưa được biên dịch**, vì máy dựng không có Xcode. Lần build đầu có thể còn vài lỗi nhỏ về kiểu dữ liệu hoặc concurrency cần sửa. Module `RTSPPush` có test đi kèm.
- Nên làm tiếp:
  - RTSP pull input (qua FFmpeg hoặc tự viết client)
  - NDI vào/ra (cần đăng ký NDI SDK với Vizrt; **không** lấy lại bản NDI có sẵn trong bundle TopDirector)
  - Trộn nhiều nguồn âm thanh (audio follow video)
  - Title/lower-third
  - Tally và điều khiển qua OSC
  - Bitrate thích ứng theo băng thông thực tế của từng đích
  - Chuyển sang HEVC cho SRT/RTSP
  - RTSP server nội bộ để máy khác kéo luồng
