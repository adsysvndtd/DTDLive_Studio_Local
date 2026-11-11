# Đăng nhập YouTube / Facebook để tạo phiên live

Hai nút **YouTube Live** và **Facebook Live** trong màn *Đầu ra* sẽ tự tạo phiên live rồi thêm một đích RTMP(S) vào danh sách. Muốn dùng được, cần khai báo ID ứng dụng trong `project.yml` (mục `info.properties`) rồi chạy lại `xcodegen generate`.

## YouTube
1. Vào Google Cloud Console, tạo project và bật **YouTube Data API v3**.
2. Tạo OAuth client loại **iOS**, Bundle ID là `vn.com.dtdsolution.DTDStudio`.
3. Ghi Client ID vào `DTDGoogleClientID`, ví dụ `1234-abc.apps.googleusercontent.com`.
4. Kênh YouTube phải được bật tính năng live trước đó (lần đầu bật mất khoảng 24 giờ).

Phiên live được tạo ở chế độ *unlisted*, bật `enableAutoStart` và `enableAutoStop`. Nghĩa là YouTube tự lên sóng khi nhận được luồng và tự kết thúc khi luồng dừng.

## Facebook
1. Tạo app trên developers.facebook.com và thêm sản phẩm **Facebook Login**.
2. Trong mục *Valid OAuth Redirect URIs*, thêm `https://www.facebook.com/connect/login_success.html`.
3. Xin quyền `publish_video`. Trong lúc app còn ở chế độ Development, chỉ admin/tester của app dùng được. Muốn dùng công khai thì phải qua App Review.
4. Ghi App ID vào `DTDFacebookAppID`.
5. Tính năng này cần iPadOS/iOS 17.4 trở lên.

Facebook chỉ nhận H.264. Nếu encoder đang để HEVC, hãy chuyển về H.264 trước khi phát.

Token chỉ lưu trong bộ nhớ: mỗi lần mở lại app phải đăng nhập lại. App không lưu mật khẩu.
