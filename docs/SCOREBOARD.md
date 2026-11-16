# Bảng tỉ số theo luật (DTD Studio)

Bảng tỉ số hiện có (kiểu DTDLive: cổ điển, chrome, lửa đỏ, vát góc, sân vận động, gọn ở góc) giờ có thêm **engine luật** cho từng môn.
Chọn môn ở chip vàng cạnh chữ "Bảng tỉ số" (hoặc trong *Sửa bảng tỉ số → Luật thi đấu*). Chọn "Tự do (+/−)" để quay lại chấm tay như cũ.

| Môn | Mẫu | Luật |
|---|---|---|
| Pickleball | đôi 11 · đơn 11 · rally 21 | Side-out: chỉ bên giao ghi điểm, đôi bắt đầu 0-0-2, server 1 → 2 → đổi giao; game 11 cách 2; đổi sân giữa game quyết định; hội ý 2/game. |
| Cầu lông | 3×15 (BWF từ 04/01/2027) · 3×21 | Rally; 20-20 → điểm 21 thắng (3×21: 29-29 → 30); nghỉ ở 8 (11); bên thắng game giao trước; ô giao phải/trái. |
| Bóng chuyền | trong nhà · bãi biển | Set 25 / set quyết định 15, cách 2; hội ý, thay người; đổi sân ở 8 (bãi biển mỗi 7 / 5 điểm). |
| Bóng đá | sân 5 · sân 7 · futsal · sân 11 | Đồng hồ trận (đếm lên / ngược), bù giờ, phút ghi bàn, phản lưới, thẻ vàng/đỏ (vàng 2 → đỏ), lỗi tích lũy, hội ý, hiệp phụ, luân lưu 5 lượt + đột tử. |
| Bi-a | 9 bi · 8 bi · 10 bi · carom 3 băng · tự do | Pool: chạm N rack, phá luân phiên / thắng được phá, HILL-HILL, đồng hồ cơ + gia hạn. Carom: series, lượt, HR, trung bình, lượt cân bằng, giới hạn lượt. |

## Điều khiển

- **Thanh bảng tỉ số** (màn hình chính): nút "+" mỗi bên = hành động chính của môn (thắng rally / bàn thắng / thắng rack), hoàn tác, nút **Nhập điểm**.
- **Nhập điểm** (form nổi, kéo lên/xuống được, vẫn bấm được bàn trộn phía sau khi ở nửa màn hình): xem trước đúng hình lên sóng, toàn bộ nút theo luật (thẻ, lỗi, hết hiệp, luân lưu, đổi lượt, đồng hồ cơ…), hoàn tác / làm lại, bật tắt trên sóng, trận mới.
- **Sửa bảng tỉ số**: tên, logo, màu, kiểu vẽ, vị trí/cỡ như trước + mục *Luật thi đấu* (số điểm, số set, số hiệp, phút/hiệp, lỗi tích lũy, luân lưu, race to, đồng hồ cơ…).
- Hoàn tác điểm số tách riêng với hoàn tác đồ hoạ.

## Web (điện thoại / laptop cùng mạng)

`http://<ip-ipad>:8080/scoreboard` — chọn môn, đổi tên đội, bấm điểm, lên sóng, hoàn tác. Trang remote cũ (`/`) có link sang.

API (cho Companion / Stream Deck / hệ thống khác):

```
GET  /api/scoreboard                         trạng thái + danh sách nút (id) của môn hiện tại
POST /api/scoreboard/action?id=rally-home    bấm một nút (id lấy từ /api/scoreboard; input= tên cầu thủ nếu cần)
POST /api/scoreboard/template?t=futsal       đổi môn (t rỗng = tự do)
POST /api/scoreboard/undo | /redo | /restart
POST /api/scoreboard/teams?home=...&away=...
POST /api/scoreboard/show?on=1
OSC  /dtd/sb "rally-home"   ·   /dtd/sb/undo
```

API cũ `/api/score?a=&b=` và OSC `/dtd/score` vẫn chạy: ở chế độ theo luật, tăng số = bấm nút chính của bên đó, giảm số = hoàn tác.
