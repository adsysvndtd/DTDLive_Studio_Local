# Ghép nối camera qua Wi-Fi (DTD Pairing v1)

Tài liệu này dành cho app camera (DTDLive hoặc app khác) muốn kết nối vào DTD Studio mà người dùng **không phải nhập mã**. Cách xác nhận: hai màn hình hiện **cùng một ID 6 số**, người vận hành so khớp rồi bấm *Chấp nhận* trên DTD Studio.

## 1. Tìm DTD Studio trong mạng
- Duyệt Bonjour dịch vụ `_dtdstudio._tcp`. TXT record gồm: `v=1`, `api=/api/pair`.
- Cổng HTTP mặc định là 8080.
- iOS: khai báo `NSBonjourServices = ["_dtdstudio._tcp"]` và `NSLocalNetworkUsageDescription` trong Info.plist của app camera.

## 2. Gửi yêu cầu ghép nối
```
POST http://<studio>:8080/api/pair/request
Content-Type: application/json
{
  "deviceID": "UUID cố định của thiết bị (identifierForVendor)",
  "name": "iPhone 16 Pro · Thanh",
  "model": "iPhone17,1",
  "app": "DTDLive",
  "protocols": ["srt"],             // thứ tự ưu tiên: "srt" | "rtsp" | "rtmp"
  "pullURL": null,                  // với rtsp/rtmp: URL để Studio kéo luồng (RTSP server trên máy, hoặc RTMP trên server)
  "nonce": "chuỗi ngẫu nhiên mới cho mỗi lần",
  "token": "token đã lưu (nếu từng ghép nối)"   // để kết nối lại tự động
}
→ { "status": "pending", "requestId": "…", "confirmCode": "482 913", "studioId": "…" }
```
- **ID xác nhận** = 6 số đầu của `SHA-256("<studioId>|<deviceID>|<nonce>")`, lấy 4 byte đầu dạng big-endian rồi mod 1 000 000, hiển thị dạng `NNN NNN`.
- App camera **tự tính** ID từ `studioId` (nhận trong phản hồi) và hiện ID đó. Không hiện lại `confirmCode` server trả về. Nhờ vậy hai bên so được với nhau, và một server giả mạo không thể ép thiết bị hiện mã do nó chọn.

## 3. Chờ người vận hành chấp nhận
```
GET http://<studio>:8080/api/pair/status?id=<requestId>    (gọi lại mỗi 1 giây, hết hạn sau 2 phút)
→ {"status":"pending"} | {"status":"rejected"} | {"status":"expired"}
→ {
    "status": "accepted",
    "inputName": "iPhone 16 Pro · Thanh",
    "protocolUsed": "srt",
    "pushURL": "srt://192.168.1.20:9101?mode=caller&passphrase=<token>&pbkeylen=16&latency=120000&streamid=<deviceID>",
    "token": "32 ký tự hex — lưu lại để lần sau tự kết nối",
    "tallyURL": "http://192.168.1.20:8080/api/tally?name=…"
  }
```
- **SRT:** Studio mở một SRT listener riêng cho từng thiết bị, có mã hoá AES-128 dùng `passphrase` = token. App camera phát luồng tới `pushURL`.
- **RTSP / RTMP:** Studio tự kéo luồng từ `pullURL`, app camera chỉ cần đang phát.
- **Tally:** gọi `tallyURL` khoảng 300 ms một lần, kết quả `{"program":bool,"preview":bool}`.

## 4. Kết nối lại
Gửi lại `/api/pair/request` kèm `token` đã lưu. Nếu Studio đang bật *Tự kết nối thiết bị tin cậy*, yêu cầu được chấp nhận ngay, không hiện hộp xác nhận. Trong mục Camera › Ghép nối qua Wi-Fi, người vận hành có thể **Gỡ** một thiết bị; khi đó token cũ hết hiệu lực.

## Bảo mật
- Chỉ hoạt động trong mạng LAN. Mỗi lúc có tối đa 5 yêu cầu chờ; mỗi thiết bị chỉ có một yêu cầu mở.
- Token so sánh theo thời gian hằng (chống đo thời gian để dò token). SRT luôn được mã hoá bằng passphrase riêng cho từng thiết bị.
