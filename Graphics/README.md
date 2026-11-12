# Đồ hoạ HTML5 cho DTD Studio

Mỗi template là một trang HTML nền trong suốt, khung 1920×1080. DTD Studio tải thư mục này từ Git
(Cài đặt › Đồ hoạ HTML5 › Cập nhật từ Git), nên sửa và push lên repo là app nhận bản mới.

`manifest.json` liệt kê template: `id`, `name`, `entry` (đường dẫn file HTML) và `fields`
(`id` khớp với `id` phần tử trong HTML; `type: "color"` cho ô chọn màu).

Mỗi trang phải có 4 hàm toàn cục (giống chuẩn template CasparCG):

| Hàm | Khi nào gọi |
|---|---|
| `update(json)` | khi nạp và mỗi lần sửa chữ/màu — đối tượng `{ "f0": "...", "f1": "...", "accent": "#..." }` |
| `play()` | phím **HTML On** — chạy hiệu ứng vào |
| `stop()` | tắt phím — chạy hiệu ứng ra (app giữ hình thêm ~1 giây cho hiệu ứng ra chạy hết) |
| `next()` | bước tiếp theo (template nhiều bước) |

Dùng CSS animation / Web Animations; không tải thư viện từ Internet (app có thể chạy không mạng).
