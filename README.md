# 🎬 CapSub Flutter

Ứng dụng xem phim ngắn và video nước ngoài (Hồng Quả, Bilibili, video nội bộ) tích hợp dịch phụ đề và lồng tiếng AI tiếng Việt theo thời gian thực trên di động.

---

## ✨ Tính Năng Nổi Bật

### 1. 🍿 Xem Phim Ngắn Hồng Quả (Short Drama)
- **Kho phim phong phú:** Tìm kiếm, phân loại theo thể loại, hiển thị danh sách tập đầy đủ.
- **Tải gối đầu mượt mà:** Tự động tải trước tập tiếp theo để chuyển tập không bị gián đoạn hay phải chờ đợi.
- **Tự động dọn tập cũ:** Tùy chọn tự động xóa các tập đã xem trước đó an toàn (xóa cách 3 tập) để máy không bị đầy bộ nhớ.
- **Dịch tiêu đề thông minh:** Hỗ trợ dịch tiêu đề phim sang tiếng Việt hoặc xem lại tên gốc tiếng Trung.

### 2. 📺 Hỗ Trợ Bilibili & Video Tùy Chỉnh
- **Bilibili:** Dán link hoặc tìm kiếm video Bilibili, tự động phân tích luồng phát chất lượng cao.
- **Nhập video từ máy:** Mở video có sẵn trong điện thoại, hỗ trợ xem kèm file phụ đề rời hoặc dịch file phụ đề bằng AI.

### 3. 🎙️ Dịch Phụ Đề & Lồng Tiếng AI (TTS)
- **Dịch phụ đề AI:** Tự động nhận diện và hiển thị phụ đề tiếng Việt chính xác theo ngữ cảnh.
- **Lồng tiếng AI:** Đọc thuyết minh phụ đề tự nhiên với nhiều giọng đọc tiếng Việt đa dạng.
- **Xuất file SRT:** Dễ dàng trích xuất và chia sẻ file phụ đề chuẩn định dạng `.srt`.

### 4. 🗂️ Quản Lý Lịch Sử & Đa Chọn Thông Minh
- **Gom nhóm theo phim bộ:** Quản lý lịch sử trực quan theo từng bộ phim, ghi nhớ chính xác tập và vị trí đang xem dở.
- **Xóa đa chọn tiện lợi:**
  - Chọn nhiều phim/video cùng lúc trên màn hình Lịch Sử để xóa nhanh.
  - Chọn nhiều tập bên trong từng phim để xóa tập đã xem tùy ý.
- **Dọn dẹp an toàn & triệt để:** Khi xóa lịch sử, hệ thống tự động xóa sạch video cache offline, audio lồng tiếng và phụ đề để giải phóng dung lượng.
- **Trình dọn dẹp bộ nhớ (Storage Cleaner):** Thống kê dung lượng cache chi tiết và dọn dẹp bộ nhớ với 1 chạm.

### 5. ⚡ Trình Phát Video Tối Ưu
- Tùy chỉnh phụ đề linh hoạt (kích cỡ, màu sắc viền/nền, vị trí hiển thị).
- Điều khiển cử chỉ vuốt nhạy bén (âm lượng, độ sáng, tua thời gian).
- Tùy chỉnh tốc độ phát và ghi nhớ tiến trình xem.

---

## 🚀 Cài Đặt Nhanh

### Cài đặt lên thiết bị qua ADB
```bash
# Build bản Release tối ưu cho thiết bị ARM64
flutter build apk --release --target-platform android-arm64

# Cài đặt trực tiếp lên điện thoại
adb install -r build/app/outputs/flutter-apk/app-release.apk
```

---

## 🛠️ Công Nghệ Sử Dụng
- **Platform:** Flutter & Dart (Android / iOS)
- **Player Engine:** Video Player & Media Resolver
- **AI & Audio:** AI Translation, TTS Voice Engine, Subtitle Document Manager
- **Storage:** Local Storage, Video Cache Manager
