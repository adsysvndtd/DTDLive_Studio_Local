# Cài DTD Studio lên iPad mà không cần cài Xcode

Mỗi lần push, GitHub Actions tạo ra các file sau trong mục **Artifacts** của lần chạy:

| Artifact | Nội dung | Cách cài |
|---|---|---|
| `DTDStudio-unsigned-ipa`, `DTDCam-unsigned-ipa` | Bản `.ipa` **chưa ký** | Ký bằng Apple ID cá nhân qua **Sideloadly** hoặc **AltStore** (cài trên Mac/Windows, nhẹ hơn Xcode rất nhiều) |
| `DTDStudio-signed-ipa` | Bản `.ipa` **đã ký Ad Hoc** (chỉ có khi đã cấu hình secrets bên dưới) | Cài thẳng qua Apple Configurator, Finder (kéo `.ipa` vào iPad), hoặc Diawi/link OTA |
| `ui-screenshots` | Ảnh chụp 10 màn hình chính ở chế độ demo trên iPad Simulator | Mở xem trực tiếp |

## Cách 1: Sideloadly (miễn phí, dùng Apple ID thường)
1. Cài Sideloadly trên Mac, cắm iPad vào máy.
2. Kéo file `DTDStudio-unsigned.ipa` vào Sideloadly, đăng nhập Apple ID rồi bấm Start.
3. Trên iPad, vào Cài đặt → Cài đặt chung → VPN & Quản lý thiết bị, chọn Tin cậy cho Apple ID vừa dùng.
4. Với Apple ID miễn phí, chứng chỉ hết hạn sau 7 ngày, khi đó cần ký lại.

## Cách 2: CI tự ký bản Ad Hoc (cần tài khoản Apple Developer 99 USD/năm)
1. Trên developer.apple.com:
   - tạo App ID `vn.vnpt.dtd.DTDStudio`
   - đăng ký UDID của các iPad
   - tạo chứng chỉ **Apple Distribution** và xuất ra file `.p12`
   - tạo provisioning profile loại **Ad Hoc** cho App ID đó
2. Mã hoá base64: `base64 -i cert.p12 | pbcopy`, rồi làm tương tự với file `.mobileprovision`.
3. Vào repo → Settings → Secrets and variables → Actions → New repository secret, thêm:
   - `IOS_CERT_P12_BASE64`: nội dung base64 của file `.p12`
   - `IOS_CERT_PASSWORD`: mật khẩu file `.p12`
   - `IOS_PROFILE_BASE64`: nội dung base64 của file `.mobileprovision`
   - `IOS_TEAM_ID`: Team ID gồm 10 ký tự
4. Push hoặc bấm Run workflow. Job **Signed DTDStudio .ipa** sẽ tạo artifact `DTDStudio-signed-ipa`.

Secrets được GitHub mã hoá, không hiện ra trong log và cũng không bị lộ trong các PR từ fork.
