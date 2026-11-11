# DTD Studio: bàn trộn hình nhiều camera và livestream cho iPad/iPhone

Đây là app viết mới hoàn toàn bằng Swift, không dùng lại mã của TopDirector. Bản TopDirector 1.9.8 cài trên máy chỉ được dùng để tham khảo kiến trúc (xem `docs/ANALYSIS.md`).

## Tính năng

| Nhóm | Chức năng |
|---|---|
| Nguồn vào | Camera trong máy, camera UVC/HDMI→USB (iPadOS 17+), SRT (caller/listener), RTMP play, **RTSP (IP camera, H.264/H.265 + AAC, tự kết nối lại)**, file video lặp, **app DTD Cam** trên iPhone (SRT/RTMP, có tally), NDI (khi có SDK) |
| Bàn trộn | PREVIEW/PROGRAM, CUT (Space), AUTO (Return), MIX/WIPE/DIP, FTB, chạm/chạm đúp trên multiview, **tự động chuyển cảnh** (lần lượt / ngẫu nhiên / theo âm thanh) |
| Xử lý hình từng nguồn | Phơi sáng, tương phản, bão hoà, nhiệt độ màu/tint, **LUT .cube**, **chroma key** (xanh lá/xanh dương, nền thay thế), lật gương, xoay 180°, cắt khung |
| Đồ hoạ | **Lower third, tên + chức danh, title toàn màn hình, chữ chạy, bảng tỉ số, đồng hồ**; logo; PiP; hiệu ứng hiện/ẩn |
| Vẽ chú thích | **Vẽ bằng Apple Pencil** (hoặc ngón tay) lên Program, nét vẽ có trong luồng phát |
| Scopes | **Histogram, Waveform, RGB Parade, Vectorscope** |
| Âm thanh | **Mixer nhiều kênh**: mic/USB, âm thanh từng nguồn SRT/RTMP, nhạc nền lặp, hiệu ứng âm thanh; gain/mute/**AFV** (âm thanh theo hình), đồng hồ mức tiếng |
| Replay | **Replay slow-motion** 0.25×–1× từ bộ đệm 15 giây (bộ đệm lưu dạng H.264 nên tốn ít RAM) |
| Đầu ra | **Push RTMP/RTMPS, SRT, RTSP**, **tạo phiên YouTube/Facebook Live tự động**, H.264 hoặc **HEVC**, **bitrate thích ứng**, ghi MP4 (phân mảnh, không hỏng file khi mất điện); nhiều đích cùng lúc; tự kết nối lại |
| Màn hình ngoài | HDMI/AirPlay: chiếu Program hoặc Multiview toàn màn hình |
| Điều khiển từ xa | **Web remote** `http://<IP iPad>:8080` (title, tỉ số, chuyển cảnh); **HTTP API** cho Bitfocus Companion / Stream Deck; **OSC** UDP 8000 |
| Tally | Gửi tới DTD Cam, đèn tally camera PTZ (VISCA), NDI tally |
| PTZ | **VISCA over IP** (UDP 52381) và VISCA TCP (5678): joystick, zoom, preset 1–6 (chạm = gọi, giữ = lưu); NDI PTZ |
| Thao tác | **Undo/Redo** (⌘Z / ⇧⌘Z) cho title, logo, PiP, xử lý hình; tự hút cạnh và lưới khi đặt PiP/logo |
| Khung hình | 1920×1080 ngang / 1080×1920 dọc |
| Show | **Lưu/nạp toàn bộ cấu hình** (nguồn, đầu ra, title, màu/LUT/key, PTZ, encoder) thành file `.dtdshow` trong Files |

### Đối chiếu với TopDirector

| TopDirector (tính năng công khai) | DTD Studio |
|---|---|
| Multicam NDI/SRT/RTSP/UVC | UVC, SRT, RTSP, RTMP, DTD Cam; NDI qua SDK |
| Stream RTMP 3 kênh + ghi file | RTMP/SRT/RTSP không giới hạn số đích + ghi MP4 |
| NDI/NDI\|HX output | NDI output khi có SDK (NDI\|HX cần license riêng) |
| TopDirectorCam + slow-motion replay | DTD Cam + replay slow-motion |
| TopDirectorTitle (title qua LAN) | Web remote, không cần cài app |
| Apple Pencil annotation | Có |
| Video scopes, color grading, LUT | Có |
| Logo, nhạc nền, PiP, watermark | Có |
| AirPlay/Screen mirroring | Có (màn hình ngoài) |
| PTZ NDI | VISCA over IP + NDI PTZ |
| Undo không giới hạn, snap | Undo 100 bước, snap |
| Đăng nhập Facebook/YouTube | Có (cần Client ID / App ID, xem `docs/PLATFORMS.md`) |

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

Có 3 target: **DTDStudio** (iPad/iPhone), **DTDCam** (camera đồng hành), **RTSPPushTests**.

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

## Cổng mạng dùng trên iPad

| Cổng | Giao thức | Dùng cho |
|---|---|---|
| 8080 | TCP/HTTP | Web remote, HTTP API, tally cho DTD Cam |
| 8000 | UDP | OSC |
| 9001 | UDP | SRT listener mặc định cho DTD Cam |

## Trạng thái

- Mã **chưa được biên dịch** vì máy dựng không có Xcode. Lần build đầu có thể còn lỗi nhỏ về kiểu dữ liệu hoặc concurrency.
- Module `RTSPPush` có unit test cho các phần: packetizer và depacketizer H.264/H.265/AAC, parser SDP, demux luồng RTSP, xác thực Digest. Chạy bằng `cd Packages/RTSPPush && swift test`.
- NDI chỉ được biên dịch khi có SDK trong `Vendor/NDI/`.
- Kết quả review: xem `docs/REVIEW.md`.
