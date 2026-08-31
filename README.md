# Photobooth Software — Pabrik Kenangan

Aplikasi photobooth kios (Flutter Windows desktop) untuk Pabrik Kenangan:
alur pembayaran → pemilihan frame → sesi foto DSLR → preview & filter → cetak 4R.

Backend API, dashboard web, dan database berada di repo/layanan terpisah;
repo ini hanya berisi aplikasi kios yang jalan di mesin di lokasi.

## Stack

- **Flutter** (Windows desktop, x64) — UI kios
- **C# / .NET Framework** — `edsdk_bridge`, proses 32-bit terpisah untuk Canon EDSDK
- **ffmpeg** — pemrosesan foto & penggabungan klip video
- Cetak lewat Windows print spooler (Epson L3210, 4R borderless)

## Struktur

| Path | Isi |
|---|---|
| `lib/screens/` | Halaman kios: splash, payment, frame, camera, preview, print |
| `lib/services/` | `edsdk_camera_service`, `capture_card_service`, `api_service`, `print_service`, `config_service` |
| `lib/utils/` | `photo_processor` (ffmpeg), `image_filter`, `frame_composer` |
| `tools/edsdk_bridge/` | **Sumber bridge Canon EDSDK** (`Program.cs`, `Edsdk.cs`, `build.ps1`) |
| `tools/` | Benchmark cetak & gambar, kalibrasi printer, setup printer, screenshot |
| `assets/bin/` | Biner pendukung — lihat `assets/bin/README.txt` |
| `refference-interface/` | Referensi desain tiap halaman |

## Canon EDSDK bridge

Aplikasi ini **tidak** memakai EOS Webcam Utility (gratisannya mentok 720p) maupun
digiCamControl (live view-nya lag). Sebagai gantinya `tools/edsdk_bridge/` bicara
langsung ke Canon EDSDK lewat P/Invoke, memberi live view ~17 fps sekaligus foto
resolusi penuh 5184×3456 (18 MP) dalam satu sesi USB.

Diuji pada **Canon EOS Kiss X7 / 100D / Rebel SL1** dengan EDSDK 13.18.40 (32-bit).

Temuan penting saat membangun binding-nya:

- Seluruh export EDSDK x86 13.18.40 memakai **`__stdcall`** (terbukti dari epilog
  `ret 8` / `ret 0Ch`). Varian `*Cdecl` pada binding lama hanya untuk EDSDK generasi
  sebelumnya — jangan dipakai.
- `EdsDirectoryItemInfo.Size` bertipe **UInt64**, bukan UInt32; struct-nya 288 byte
  di x86. `EdsCapacity` memakai `Pack = 2`.
- **Jangan pre-alokasi stream live view.** `EdsCreateMemoryStream(1MB)` membuat
  `EdsGetLength` mengembalikan ukuran *alokasi*, bukan byte terpakai, sehingga frame
  berisi sampah. Pakai ukuran 0.
- `kEdsPropID_Evf_AFMode` adalah penentu fps terbesar: LiveMulti 11,7 fps →
  Quick 19,0 fps. Default bridge memakai **Live (1)** karena mode Quick membuat
  preview blur (AF fase butuh cermin turun).
- Stdin harus dibaca lewat **P/Invoke `ReadFile` pada `GetStdHandle(-10)`**. Ketiga
  cara `Console.In` .NET memblokir selamanya bila parent-nya proses Dart/Flutter.
- Bridge dibaca di thread background + watchdog `--idle-timeout`; bridge yatim akan
  menahan sesi USB dan membuat sesi berikutnya diam-diam jatuh ke EOS Webcam.

Bridge harus 32-bit karena `EDSDK.dll` 32-bit, sedangkan `photobooth_app.exe` 64-bit —
karenanya ia berjalan sebagai proses terpisah, bukan DLL yang di-load in-process.

Build:

```powershell
powershell -ExecutionPolicy Bypass -File tools\edsdk_bridge\build.ps1
powershell -ExecutionPolicy Bypass -File tools\edsdk_bridge\test-bridge.ps1   # uji tanpa app
```

## Setup di device baru

Clone saja **tidak cukup** untuk menjalankan app — ada satu penghadang lisensi
(langkah 5) yang membuat app berhenti di splash screen kalau dilewati.

### 1. Prasyarat

| Kebutuhan | Keterangan |
|---|---|
| **Flutter stable 3.44.2** | Dart SDK `>=3.0.0 <4.0.0`. `flutter doctor` harus hijau untuk Windows. |
| **Visual Studio 2022** + workload *Desktop development with C++* | Wajib untuk `flutter build windows`. Build Tools saja cukup, tidak perlu IDE penuh. |
| **WebView2 Runtime** | Dipakai `webview_windows` untuk halaman pembayaran DOKU. Sudah bawaan Windows 11; di Windows 10 pasang manual. |
| **.NET Framework 4** | Hanya bila mau **build ulang** bridge EDSDK. Sudah ada di semua Windows — `build.ps1` memakai `csc.exe` bawaan, tidak perlu .NET SDK. |

### 2. Clone & dependensi

```powershell
git clone https://github.com/zakaaaaa/photbooth-software.git
cd photbooth-software
flutter pub get
```

### 3. ffmpeg (tidak ikut di repo)

`assets/bin/ffmpeg.exe` (136 MB) melewati batas 100 MB GitHub, jadi harus diunduh
sendiri: ambil static build Windows dari <https://www.gyan.dev/ffmpeg/builds/>
(`ffmpeg-release-essentials.zip`), salin `bin\ffmpeg.exe` ke `assets/bin/`.

Alternatif: set env `FFMPEG_PATH`, atau taruh di PATH. Urutan pencarian lengkap
ada di `assets/bin/README.txt`.

App tetap jalan tanpa ffmpeg, tapi pemrosesan foto jatuh ke `package:image` yang
**~6x lebih lambat** — 5,4 detik vs 0,9 detik per foto 18 MP, terasa jelas sebagai
jeda setelah setiap jepretan.

### 4. Kamera Canon (opsional saat development)

`EDSDK.dll`, `EdsImage.dll`, dan `edsdk_bridge.exe` **sudah ikut di repo**, jadi
tidak perlu memasang digiCamControl di device baru. Cukup colok kamera lewat USB.

Build ulang bridge hanya perlu kalau kamu mengubah `Program.cs` / `Edsdk.cs`:

```powershell
powershell -ExecutionPolicy Bypass -File tools\edsdk_bridge\build.ps1
powershell -ExecutionPolicy Bypass -File tools\edsdk_bridge\test-bridge.ps1
```

Catatan: `build.ps1` juga mencoba menyalin ulang kedua DLL dari
`C:\Program Files (x86)\digiCamControl`. Kalau digiCamControl tidak terpasang ia
hanya memberi peringatan dan memakai DLL yang sudah ada di repo — aman.

Tanpa kamera Canon tercolok, `_initCamera` otomatis mundur ke sumber berikutnya
(capture card, lalu webcam).

### 5. Daftarkan HWID device baru — WAJIB

App terkunci per-perangkat. Saat start, `LicenseService` mengirim
`windowsInfo.deviceId` ke `POST /api/photobooth/license/check`; kalau HWID itu
belum terdaftar, splash screen berhenti dengan pesan lisensi tidak valid dan app
tidak bisa lanjut sama sekali.

Cara mendapatkan HWID device baru:

1. Jalankan app sekali — HWID tercetak di log debug sebagai
   `DEBUG: HWID DETECTED -> <hwid>`, dan juga tampil di halaman diagnostic.
2. Daftarkan HWID itu lewat dashboard super admin di
   `www.pabrikenangan.my.id` (panel HWID), atau langsung ke tabel lisensi di
   Supabase.

Selama HWID belum terdaftar, tidak ada `--dart-define` atau konfigurasi apa pun
yang bisa melewatinya.

### 6. Jalankan

```powershell
flutter run -d windows
```

Default sudah menunjuk produksi (`https://api.pabrikenangan.my.id`). Untuk
menunjuk backend lokal atau mengubah mode AF kamera:

```powershell
flutter run -d windows `
  --dart-define=PROD_BACKEND_URL=http://192.168.1.10:3001 `
  --dart-define=PHOTOBOOTH_AF_MODE=live
```

Daftar lengkap kunci `--dart-define` ada di `lib/services/config_service.dart`.

### 7. Printer (hanya untuk mesin kios produksi)

Geometri cetak 4R borderless sudah dikalibrasi untuk **Epson L3210**. Di mesin
baru, jalankan setup printer dan verifikasi tanpa membuang kertas:

```powershell
powershell -ExecutionPolicy Bypass -File tools\setup-printer.ps1
dart run tools\print_calibration.dart
```

### Kalau app tidak jalan

| Gejala | Penyebab tersering |
|---|---|
| Berhenti di splash, pesan lisensi | HWID belum didaftarkan (langkah 5) |
| Jeda ~5 detik tiap jepret | `ffmpeg.exe` belum ada di `assets/bin/` (langkah 3) |
| Halaman pembayaran kosong / error WebView2 | WebView2 Runtime belum terpasang |
| Kamera jatuh ke webcam 720p | `edsdk_bridge.exe` yatim masih memegang sesi USB — `taskkill /IM edsdk_bridge.exe` |
| `MSB3021` saat build | `photobooth_app.exe` masih jalan mengunci DLL — `Stop-Process -Name photobooth_app -Force` |

## Catatan

`assets/bin/EDSDK.dll` dan `EdsImage.dll` adalah runtime milik Canon yang disalin
dari instalasi digiCamControl. Untuk distribusi komersial, ganti dengan DLL hasil
registrasi resmi di Canon Developer Programme.

Skrip `.ps1` di repo ini **wajib disimpan UTF-8 dengan BOM** — PowerShell 5.1
membaca skrip tanpa BOM sebagai ANSI dan karakter em-dash akan merusak parsing.
