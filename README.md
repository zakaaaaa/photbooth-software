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

## Menjalankan

```bash
git clone https://github.com/zakaaaaa/photbooth-software.git
```

**`ffmpeg.exe` tidak ikut di repo** (136 MB, melewati batas 100 MB GitHub). Unduh
static build Windows dari <https://www.gyan.dev/ffmpeg/builds/>
(`ffmpeg-release-essentials.zip`), ambil `bin\ffmpeg.exe`, taruh di
`assets/bin/`. Alternatifnya set env `FFMPEG_PATH` atau letakkan di PATH —
urutan pencarian ada di `assets/bin/README.txt`. Tanpa ffmpeg, pemrosesan foto
jatuh ke `package:image` yang ~6x lebih lambat (5,4 detik vs 0,9 detik per foto 18 MP).

Lalu:

```powershell
flutter pub get
flutter run -d windows
```

Endpoint diatur lewat `--dart-define` (lihat `lib/services/config_service.dart`),
default produksi `https://api.pabrikenangan.my.id`. Mode AF kamera bisa
diubah dengan `--dart-define=PHOTOBOOTH_AF_MODE=live|face|multi|quick|keep`.

## Catatan

`assets/bin/EDSDK.dll` dan `EdsImage.dll` adalah runtime milik Canon yang disalin
dari instalasi digiCamControl. Untuk distribusi komersial, ganti dengan DLL hasil
registrasi resmi di Canon Developer Programme.

Skrip `.ps1` di repo ini **wajib disimpan UTF-8 dengan BOM** — PowerShell 5.1
membaca skrip tanpa BOM sebagai ANSI dan karakter em-dash akan merusak parsing.
