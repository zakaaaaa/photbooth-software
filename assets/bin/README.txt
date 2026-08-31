BINER PENDUKUNG (di-bundle ke rilis lewat pubspec assets)
=========================================================

Folder ini ikut tersalin ke hasil build, jadi apa pun yang ditaruh di sini
otomatis terbawa ke:
   build\windows\x64\runner\Release\data\flutter_assets\assets\bin\

Isi:

1) ffmpeg.exe          — untuk fitur "Video" (menggabungkan klip tiap foto)
2) edsdk_bridge.exe    — jembatan ke Canon EDSDK (kontrol kamera DSLR)
3) EDSDK.dll           — runtime Canon EDSDK 13.18.40 (32-bit)
4) EdsImage.dll        — pendamping EDSDK.dll


-------------------------------------------------------------------
1. FFMPEG
-------------------------------------------------------------------
Unduh static build Windows, mis. https://www.gyan.dev/ffmpeg/builds/
("ffmpeg-release-essentials.zip"), ambil bin\ffmpeg.exe.

Aplikasi mencari ffmpeg berurutan di:
   <folder exe>\ffmpeg.exe
   <folder exe>\data\flutter_assets\assets\bin\ffmpeg.exe
   <root proyek>\ffmpeg.exe  /  tools\ffmpeg.exe  /  assets\bin\ffmpeg.exe
   env FFMPEG_PATH
   PATH sistem


-------------------------------------------------------------------
2. EDSDK BRIDGE (kamera Canon EOS)
-------------------------------------------------------------------
edsdk_bridge.exe memberi live view + foto resolusi penuh dari Canon EOS
lewat satu sesi USB, menggantikan EOS Webcam Utility (versi gratisnya
mentok 720p) dan digiCamControl (live view-nya lag).

Sumber & cara build ada di  tools\edsdk_bridge\  :
   powershell -ExecutionPolicy Bypass -File tools\edsdk_bridge\build.ps1

Skrip build itu SEKALIGUS menyalin EDSDK.dll + EdsImage.dll ke sini.

PENTING — arsitektur:
   edsdk_bridge.exe WAJIB 32-bit karena EDSDK.dll yang dipakai 32-bit.
   Itulah alasan ia proses terpisah: photobooth_app.exe adalah 64-bit dan
   tidak bisa me-load DLL 32-bit di dalam prosesnya sendiri.
   Ketiga file (exe + 2 dll) HARUS berada di folder yang sama.

Uji tanpa menjalankan app:
   powershell -ExecutionPolicy Bypass -File tools\edsdk_bridge\test-bridge.ps1

Asal EDSDK.dll:
   Disalin dari C:\Program Files (x86)\digiCamControl\ (versi 13.18.40).
   Untuk distribusi komersial ke klien, ganti dengan DLL hasil registrasi
   resmi di Canon Developer Programme.


-------------------------------------------------------------------
CATATAN REPO
-------------------------------------------------------------------
ffmpeg.exe (143 MB) dan EDSDK.dll/EdsImage.dll TIDAK ideal untuk di-commit.
ffmpeg diunduh manual; kedua DLL Canon dihasilkan ulang oleh build.ps1
selama digiCamControl masih terpasang di mesin build.
