# Phân tích TopDirector 1.9.8 (bản cài trên máy)

Phạm vi: chỉ đọc cấu trúc bundle, danh sách framework và tên lớp/ký hiệu trong các framework **không mã hóa**, để hiểu kiến trúc. Không có mã nào từ TopDirector được chép sang DTD Studio.

## Bundle

- `com.topdirector.topdirector` bản 1.9.8 (61015), cần iOS 18 trở lên, chạy được trên iPhone và iPad.
- Có khai báo `UIBackgroundModes=audio` và Bonjour `_ndi._tcp`.
- **Binary chính `TopDirector` bị mã hóa FairPlay (`cryptid=1`)** vì cài từ App Store. Việc giải mã FairPlay là vượt cơ chế DRM của Apple nên không thực hiện. Nếu cần xem sâu hơn, nên xin TopDirector bản build không mã hóa hoặc mã nguồn.

## Các framework đi kèm (đều không mã hóa)

| Framework | Vai trò |
|---|---|
| TopDirectorFramework (10 MB) | Lõi xử lý media: nguồn, trộn hình, scopes, streaming |
| TopDirectorFFMpegLibrary (19 MB) | FFmpeg đóng gói lại, khả năng dùng cho RTSP input và demux |
| TopDirectorNDILibrary (3.3 MB) | Bọc NDI SDK |
| libsrt | Haivision SRT |
| FBSDK*, GoogleSignIn, AppAuth | Đăng nhập để phát lên Facebook/YouTube |

## Kiến trúc suy ra từ tên lớp trong TopDirectorFramework

- **Đồ thị node:** `AVNode` → `AVInputNode`/`AVOutputNode`. Các nguồn: `AVCameraSource`, `AVIUVCCameraSource`/`AVUVCMultiCamCapture`, `AVSRTReceiver`, `AVRTSPSource`, `AVNDIReciever`, `AVMovieSource`, `AVImageSource`, `AVChromaKeySource`.
- **Xử lý hình:** `AVBasicProcesser`, `AVDoubleThreadProcesser`, `AVTripleThreadProcesser` (pipeline 1, 2, 3 luồng) cùng `CPixelBufferPoolManager`.
- **Hiệu ứng:** dựng trên các bộ lọc có sẵn của Core Image. `CIDissolve`/`Swipe`/`PageCurl`/`Ripple`/`Flash`/`Mod`/`BarsSwipe`/`CopyMachine`/`AccordionFold` để chuyển cảnh; `CIChromaKey`, `CILUTAdjust`, `CISkinSmoothing`, `CIKenBurns` cho xử lý hình.
- **Scopes:** Histogram, Waveform, Parade, Vectorscope.
- **Streaming:** dùng thư viện mã nguồn mở **HaishinKit** (module `RTMPHaishinKit`, `SRTHaishinKit`, license BSD-3).
- **Ghi hình:** `AVMovieRecorder`/`AVWriterRecording` (dùng AVAssetWriter).
- **Âm thanh:** `AudioIOMixer`, `AudioTapProcessor`.
- Framework hệ thống được dùng: Metal, CoreImage, VideoToolbox, AVFoundation, Network.

## Áp dụng vào DTD Studio

- Dùng cùng thư viện mở HaishinKit cho RTMP/SRT. Phần còn lại tự viết bằng các API hệ thống.
- Bổ sung những gì bản cũ không có, hoặc là điểm yếu theo đánh giá người dùng trên App Store:
  - **Push RTSP:** module `RTSPPush` tự viết theo RFC 2326/3550/6184/3640.
  - **Push SRT ra nhiều đích cùng lúc**, mỗi đích có hàng đợi riêng.
  - **Tự kết nối lại** khi rớt mạng.
  - **Encode 1 lần cho nhiều đích**, đỡ tốn tài nguyên. Người dùng từng phàn nàn bản cũ crash khi chạy 5–6 camera.
