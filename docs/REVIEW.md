# Review mã (2026-11-11)

Review thủ công toàn bộ mã nguồn trước lần build đầu. Dưới đây là các lỗi đã sửa và các rủi ro còn lại.

## Đã sửa

| # | Vị trí | Vấn đề | Cách sửa |
|---|---|---|---|
| 1 | `VideoEncoder` | `encode()` chạy trên luồng render, trong khi đổi codec/bitrate và xin keyframe đến từ main thread hoặc actor → có thể dùng session đã bị huỷ | Thêm `NSRecursiveLock` bao mọi thao tác truy cập session |
| 2 | `VideoEncoder` | Tạo lại session (khi đổi khung hình hoặc codec) thì mất bitrate do ABR đang hạ | Lưu `liveBitrate` và dùng khi tạo session mới |
| 3 | `OutputManager` | Đổi codec hoặc kích thước thì RTSP/MP4 vẫn giữ SDP và header cũ | Phát hiện parameter set thay đổi → `OutputSlot.reconnect` |
| 4 | `OutputManager` | Ban đầu mỗi frame được gửi bằng một `Task` riêng → frame có thể đến sai thứ tự | Mỗi đích có một hàng đợi `AsyncStream` riêng, giữ đúng thứ tự |
| 5 | `RecordOutput` | AAC passthrough không có magic cookie → AVAssetWriter có thể từ chối | Gắn AudioSpecificConfig làm cookie |
| 6 | `H264/H265Depacketizer` | Mất gói đúng lúc chuyển frame thì cờ `broken` bị xoá mất → giải mã frame lỗi | Đánh dấu hỏng cả frame cũ lẫn frame mới |
| 7 | RTSP clients | Keep-alive chạy song song với TEARDOWN thì một continuation bị ghi đè và treo | Mỗi lúc chỉ cho một request đang chờ phản hồi |
| 8 | `Switcher.auto` | AUTO khi preview trống hoặc trùng program thì program thành màn trống | Bỏ qua (không làm gì) |
| 9 | Cổng mạng | OSC dùng UDP 9000, trùng ví dụ SRT listener | OSC chuyển sang UDP 8000, SRT mặc định 9001 |
| 10 | `AppDelegate` | Trả về cấu hình scene tự đặt tên cho scene chính, có thể phá WindowGroup của SwiftUI | Chỉ xử lý màn hình ngoài; scene chính trả `session.configuration` |
| 11 | `AudioEncoder` | Đọc magic cookie qua KVC (không có API đó) | Bỏ; dùng ASC tự tính |

## Rủi ro còn lại (cần kiểm tra trên máy thật)

- **Hiệu năng.** Switcher dựng cả PROGRAM và PREVIEW ở 1080p30 bằng CoreImage. Trên iPad đời M1 trở lên thì ổn. Máy A12/A13 nên giảm preview xuống 720p.
- **Audio mixer.** `AudioCapture.feed` lên lịch phát buffer trên main thread. Khi có nhiều nguồn SRT/RTSP cùng có tiếng, có thể bị trễ, cần đo thực tế.
- **ABR.** Chỉ đo được hàng đợi phía app và hàng đợi gửi RTSP. Bộ đệm bên trong HaishinKit (RTMP/SRT) không đo được, nên trên mạng xấu bitrate có thể giảm chậm hơn cần thiết.
- **Facebook Live.** Cần app có quyền `publish_video` đã qua App Review, và iOS 17.4 trở lên.
- **NDI.** Bộ bọc NDI viết theo C API của NDI SDK 5/6 nhưng chưa biên dịch thử với SDK thật.
- **Swift 6 strict concurrency.** Project đang để `SWIFT_VERSION 5`. Chuyển sang Swift 6 sẽ phát sinh cảnh báo hoặc lỗi về `Sendable` ở các closure callback.
