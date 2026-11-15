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

## Bộ overlay phát sóng (thiết kế gốc DTD)

| Thư mục | Mẫu | Ghi chú |
|---|---|---|
| `news-frame` | Khung bản tin trực tiếp (Xanh, Đỏ) | Tên kênh/logo + LIVE + giờ ở trên; tiêu đề, dòng phụ, chữ chạy ở dưới. Chữ chạy trống thì ẩn; giờ `-` thì ẩn |
| `breaking` | Tin nóng | Dải chữ lớn quét ngang rồi thu thành nhãn, tiêu đề trượt ra. **Tiếp** = chạy lại hiệu ứng |
| `neon-frame` | Khung neon livestream | Viền phát sáng chạy màu (2 màu), nhãn kênh + ảnh đại diện, LIVE |
| `podcast` | Banner podcast | Micro (hoặc logo), tên chương trình, tiêu đề tập, khách mời, sóng âm động |
| `starting-soon` | Màn chờ · Sắp bắt đầu / Quay lại ngay | Toàn màn hình, nền động, đếm ngược theo số phút (trống = không đếm). **Tiếp** = đếm lại |

Không dùng tài nguyên tải từ thư viện ảnh stock (Freepik/Magnific…): giấy phép của họ không cho đóng gói vào app làm template.

## Font và chữ tự co

`fonts/` chứa các font có đủ dấu tiếng Việt (Montserrat, Be Vietnam Pro, Roboto, Oswald, Barlow Condensed,
Anton, Playfair Display — giấy phép SIL OFL, xem `fonts/LICENSES.txt`). App tự nạp chúng vào mọi trang, kể cả HTML
bạn nhập: chỉ cần ghi `font-family: "Be Vietnam Pro"` (hoặc tên font khác ở trên) trong CSS. Trong app, mục
Thiết kế › Lớp › Font cũng chọn được các font này.

Chữ dài hơn khung sẽ tự thu nhỏ (tối đa còn một nửa cỡ chữ) thay vì tràn ra ngoài. Điều kiện: khung có chiều rộng
giới hạn (`width` / `max-width`) và chữ không xuống dòng (`white-space: nowrap`), hoặc khung có chiều cao cố định.
Thêm `data-fit="off"` vào phần tử nào không muốn tự co.

## Nhập file HTML của riêng bạn (trong app: Đồ hoạ HTML5 › Nhập HTML)

Chọn một file `.html` hoặc cả thư mục (có `index.html` + ảnh, font, css). App tự tìm phần sửa được:

- Phần tử có `data-field="tên"` → ô sửa chữ (tuỳ chọn `data-label="Nhãn hiển thị"`, `data-default="…"`).
  `<img data-field="logo">` → chọn ảnh từ thư viện Logo.
- Biến màu CSS trong trang, ví dụ `--accent: #5172BE;` → ô chọn màu (kèm các màu mẫu).
- Nếu không có `data-field`, các phần tử có `id` chứa chữ sẽ thành ô sửa.

Trang không cần tự viết `update/play/stop/next`: app tự bổ sung (điền chữ theo `data-field`, hiệu ứng mờ vào/ra).
Trang nhập vào lưu ở `Documents/GraphicsUser`, không bị ghi đè khi cập nhật từ Git.
Nhấn giữ một mẫu để Sửa mã HTML (có xem trước), Nhân bản, Đổi tên, Xoá. Mẫu có sẵn được nhân bản rồi mới sửa.

Ví dụ tối thiểu:

```html
<style>:root{--accent:#C84B33} .bar{background:var(--accent);color:#fff;font:800 64px sans-serif;padding:20px 40px;position:absolute;left:80px;bottom:120px}</style>
<div class="bar"><span data-field="name" data-label="Họ tên">Nguyễn Văn A</span></div>
```
