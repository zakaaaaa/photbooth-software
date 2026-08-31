# 🎨 Brief Generate Mockup UI/UX — Pabrik Kenangan (Photobooth App)

> **Tujuan dokumen:** instruksi lengkap & siap-pakai untuk menghasilkan mockup UI/UX baru aplikasi photobooth desktop **Pabrik Kenangan**. Bisa di-paste ke AI image/mockup generator (Midjourney, DALL·E, Figma AI, Galileo, Uizard) atau diberikan ke desainer.
>
> **Platform:** Aplikasi **desktop Windows kiosk**, layar penuh **landscape 16:9** (rasio 1920×1080). Disentuh/diklik di tempat (touchscreen kiosk), jadi target sentuh harus besar.

---

## 1. Konsep & Mood Desain

Nama brand **"Pabrik Kenangan"** (Pabrik = factory, Kenangan = memories) → *"pabrik yang memproduksi kenangan"*. Gaya diturunkan dari **logo**: kartu kertas robek (torn paper) dengan **lettering tangan**, ilustrasi **kamera + roll film**, di atas latar **patchwork/jahitan kain hangat**.

**Mood inti:** `Cozy` · `Craft / Handmade` · `Nostalgic / Analog` · `Warm` · `Playful tapi tenang`.

**Prinsip utama: EYE-CATCHING TAPI SIMPLE**
- Menonjol lewat **warna hangat & tekstur**, bukan lewat banyak elemen.
- 1 layar = 1 fokus utama (1 aksi besar). Hindari clutter.
- Banyak *breathing space*; elemen besar & ramah sentuh.
- Detail craft (jahitan, kertas, film strip) jadi *aksen*, bukan dominan.

---

## 2. Referensi Software (gaya pendekatan serupa)

Gunakan kombinasi rasa dari aplikasi berikut:

| Aplikasi | Yang diambil |
|---|---|
| **Animal Crossing / Cozy Grove** | Kehangatan, rasa handmade, UI membulat & ramah, ikon ilustratif lucu |
| **Duolingo** | Tombol besar membulat, bold, playful, sangat *kiosk-friendly*, 1 aksi dominan per layar |
| **Gudak Cam / Dazz Cam / 1888 / Lapse** | Estetika kamera analog/retro film — relevan langsung untuk photobooth |
| **Alto's Odyssey** | "Eye-catching tapi simple" lewat gradient hangat & minimalis, atmosfer tenang |
| **Headspace** | Ilustrasi lembut, palet hangat, friendly, simpel |
| **Etsy / Pinterest (brand warmth)** | Nuansa craft/textile, kertas, kerajinan tangan |

**Benang merah:** hangat + handmade + 1 aksi besar yang jelas + estetika film analog.

---

## 3. Palet Warna (diturunkan dari logo & patchwork)

```
PRIMARY (Brick Red — aksi utama / tombol)
  #C23A2A  base
  #D0452F  hover (lebih terang)
  #A62D1D  pressed / shadow (lebih gelap)

NETRAL HANGAT (kertas / permukaan)
  #FBF4E6  paper / kartu terang
  #F5ECD9  cream background
  #E8DBC2  cream gelap / border halus

INK / TEKS (cokelat hangat, bukan hitam murni)
  #2A1812  ink utama (judul)
  #4A2E22  teks medium
  #7A6259  teks muted / sekunder
  #9E8880  teks light / placeholder

AKSEN PATCHWORK (untuk tekstur, kategori, ilustrasi)
  #8A9A5B  sage / olive green
  #6E7A45  olive gelap
  #D9A441  mustard / ochre
  #D2703A  terracotta orange
  #4A2420  maroon (latar dinding/scene gelap)

SEMANTIK (status — versi hangat)
  Sukses  #5E8C61 (sage hijau) — hindari hijau neon
  Warning #D9A441 (mustard)
  Error   #B23320 (merah-bata gelap)
```

**Aturan warna:**
- Latar dominan = **cream/paper hangat** atau **scene patchwork**, BUKAN putih murni / abu dingin.
- Merah-bata HANYA untuk aksi utama & aksen kunci (jangan tebar di mana-mana).
- Teks = cokelat hangat (`#2A1812`), **jangan** `#000000`.
- Buang total palet lama: biru Win95 (`#0000AA`), silver (`#C0C0C0`), kuning neon (`#FFED00`).

---

## 4. Tipografi

| Peran | Font | Catatan |
|---|---|---|
| **Display / Headline** | **Genty** (atau marker/handdrawn serupa) | Untuk judul besar seperti "Design / UR MEMORY" — beri kesan tulisan tangan craft |
| **Body / UI** | **Poppins** | Bersih, membulat, ramah; weight 400–700 |
| **Aksen kecil / kode** | monospace | Hanya untuk kode transaksi/HWID |

- Headline besar & berani (bisa 2 baris: kata script + kata kapital spasi lebar).
- Hindari teks beroutline pixel gaya lama. Pakai *drop shadow* lembut bila perlu kontras di atas foto/scene.
- Hierarki jelas: 1 judul besar, sub kecil, body ringkas.

---

## 5. Komponen & Gaya Visual

**Tombol utama (primary):**
- Bentuk **pill** (radius penuh ~40px) ATAU rounded-rect besar (radius 20–28px).
- Isi gradient merah-bata (`#D0452F → #A62D1D`), teks putih + ikon panah.
- Shadow hangat lembut (offset bawah, blur sedang). **Bukan** bevel kotak 3D.
- **Hover/press:** scale 1.04–1.06, shadow menebal, ikon panah geser sedikit ke kanan.
- Ukuran besar, ramah sentuh (tinggi ≥ 56px).

**Tombol sekunder:** outline merah tipis di atas kertas, atau pill cream dengan teks merah.

**Kartu (frame template, dll):**
- Sudut membulat (16–22px), latar kertas/cream, border halus + shadow lembut.
- State terpilih: ring/garis merah-bata + sedikit terangkat (lift).
- Boleh detail craft: tepi seperti kertas/perangko, jahitan halus.

**Input / form:** rounded (12–14px), latar kertas, border tipis; fokus → border merah + glow halus. Di kiosk pakai **on-screen keyboard** bergaya sama.

**Modal / dialog:** kartu kertas membulat di tengah, backdrop gelap transparan, aksen merah pada header.

**Header layar:** judul Genty besar di atas-tengah; opsional logo kecil "Pabrik Kenangan" di pojok kiri-atas.

**Ikon:** gaya garis membulat / ilustratif lembut (rounded), hangat — hindari ikon tajam korporat.

---

## 6. Tekstur & Elemen Dekoratif (aksen craft)

- **Patchwork/quilt** kain hangat sebagai latar utama beberapa layar (seperti splash).
- **Tekstur kertas** robek/lipat untuk kartu & panel.
- **Jahitan (stitch)** putus-putus sebagai garis pemisah/aksen.
- **Film strip / sprocket** sebagai motif dekoratif tipis (tema kamera analog).
- **Cahaya hangat** (glow lembut dari atas) untuk fokus — seperti LIGHT.png di splash.
- Gunakan hemat: tekstur sebagai *background/aksen*, area konten tetap bersih agar simple.

---

## 7. Instruksi Mockup per Layar

Urutan flow (kiosk, 16:9). Tiap layar: **1 fokus + 1 aksi besar.** Referensi visual ada di folder `refference-interface/`.

### 7.1 Splash — *“Welcome”*  (ref: `splash.png`)
- Latar patchwork hangat penuh layar.
- Logo "Pabrik Kenangan" (kartu kertas) di tengah-atas, cahaya lembut turun dari atas.
- 1 tombol **`start →`** pill merah di bawah-tengah (besar, hover-animatif).

### 7.2 Pilih Frame — *“Design Ur Memory”*  (ref: `choose-frame.png`)
- Latar scene ruangan hangat (`STATIC-FRAME.png`).
- Headline atas-tengah: **"Design"** (Genty) + **"UR MEMORY"**.
- Kanan-atas: 2 tab ukuran kertas **"4R (1 strip)"** & **"2R (2 strip)"** (pill cream, aktif = merah).
- Tengah: baris kartu template frame (membulat, paper) + panah kiri/kanan bulat merah.
- Kanan-bawah: tombol **`capture →`** pill merah.

### 7.3 Kamera / Capture  (ref: `cam-page.png`)
- Preview kamera besar berbingkai kertas/film-strip.
- Countdown angka besar (Genty), feedback kilatan saat jepret.
- Indikator urutan foto (mis. 1/4) gaya film sprocket.
- Tombol jepret besar (bulat merah) atau auto-countdown.

### 7.4 Kustomisasi (opsional, mode dinamis)
- Kanvas foto di tengah; panel alat (filter, stiker, teks) berupa kartu samping/bawah.
- Chip filter membulat dengan preview; stiker craft; warna teks dari palet hangat.
- Tombol **`next →`** merah.

### 7.5 Preview & Print  (ref: `print-preview.png`)
- Preview strip hasil besar (gaya foto cetak di atas meja kayu/kertas).
- Opsi: jumlah cetak / extra print (stepper membulat), kirim **email / QR download**.
- Tombol utama **`print →`** merah. (Catatan flow baru: **Pembayaran terjadi DI SINI/sebelum cetak**, bukan di awal.)

### 7.6 Pembayaran  (ref: `payment.png`)
- Kartu kertas berisi QR (QRIS) besar di tengah, nominal jelas, logo Pabrik Kenangan.
- Status: *menunggu pembayaran* → *berhasil* (centang sage hijau, animasi lembut).
- Auto-lanjut setelah sukses (polling). Tombol *batal* sekunder.

### 7.7 State Pendukung (wajib dibuat konsisten)
- **Loading**: spinner/animasi hangat (mis. roll film berputar) + teks ramah.
- **Error / koneksi**: kartu kertas, ikon ramah, pesan singkat + tombol **coba lagi**.
- **Sukses**: centang sage + konfeti/craft halus.
- **Timer sesi**: badge countdown kecil pojok kanan-atas (hangat, bukan merah neon).

---

## 8. Animasi & Microinteraction

- Transisi antar layar: *fade + slide* lembut (250–400ms, easeOut).
- Entrance: elemen masuk *slide/fade* sekali (tanpa loop), mis. cahaya turun di splash.
- Tombol: hover scale + shadow + panah bergeser.
- Kartu frame: hover lift + ring merah saat terpilih.
- Countdown kamera: scale + fade angka.
- Feedback sukses: pop + centang.
> Animasi *halus & singkat* — mendukung kesan craft tenang, bukan ramai.

---

## 9. Aturan Konsistensi (Do / Don't)

**DO**
- Latar hangat (cream/patchwork), teks cokelat hangat.
- 1 aksi utama dominan per layar, target sentuh besar.
- Tekstur craft sebagai aksen; konten tetap lapang & simple.
- Tombol pill/rounded + shadow lembut + animasi hover.

**DON'T**
- ❌ Gaya lama Windows-95/pixel: bevel silver, title-bar biru, teks beroutline kuning.
- ❌ Putih murni / abu dingin / hitam murni.
- ❌ Banyak warna terang sekaligus (max ~1 aksi merah + aksen patchwork netral).
- ❌ Layar penuh kontrol kecil-kecil (bukan kiosk-friendly).

---

## 10. Spesifikasi Teknis untuk Generate

- **Rasio:** 16:9 landscape, render **1920×1080** (atau 1280×720 cepat).
- **Safe area:** beri padding ~48–64px dari tepi.
- **Target sentuh:** tombol ≥ 56px tinggi, jarak antar elemen ≥ 16px.
- **Format:** PNG mockup per layar + (opsional) varian state (default/hover/loading/success/error).
- Sertakan **logo & gambar bg** yang sudah ada (`assets/images/SPLASH.png`, `STATIC-FRAME.png`) sebagai dasar bila relevan.

---

## 11. Template Prompt (siap paste ke AI generator)

> **Prompt dasar (ganti `{NAMA LAYAR}` & `{ELEMEN}`):**

```
High-fidelity UI mockup of a photobooth kiosk app screen, landscape 16:9, 1920x1080.
Screen: {NAMA LAYAR}.
Style: cozy handmade/craft aesthetic, warm patchwork & torn-paper textures, analog film
camera vibe, friendly and playful but SIMPLE and uncluttered — one big clear action.
Inspiration: Animal Crossing coziness + Duolingo big rounded buttons + retro film camera
apps (Gudak/Dazz) + Alto's Odyssey warm minimalism.
Color palette: brick red #C23A2A (primary action), warm cream paper #FBF4E6 / #F5ECD9,
warm brown ink #2A1812, accents sage green #8A9A5B, mustard #D9A441, terracotta #D2703A.
Typography: handwritten display font (Genty-like) for big headline, Poppins for UI text.
Components: pill / large rounded buttons with soft warm shadows and arrow icons,
rounded paper cards with subtle stitching, generous spacing, large touch targets.
Elements: {ELEMEN — mis. headline "Design Ur Memory", row of frame template cards, paper-size
tabs 4R/2R, red "capture →" button bottom-right}.
NO Windows-95 bevel buttons, NO cold gray/blue, NO pure white, NO clutter.
Soft warm lighting glow from top. Clean, eye-catching, premium-cozy.
```

> Buat 1 prompt per layar (splash, choose-frame, camera, customization, print-preview, payment) + variasi state.

---

### Lampiran — Aset & referensi yang sudah ada
- Logo & bg: `assets/images/SPLASH.png`, `assets/images/STATIC-FRAME.png`, `assets/images/LIGHT.png`
- Referensi layout: `refference-interface/splash.png`, `choose-frame.png`, `cam-page.png`, `print-preview.png`, `payment.png`
- Font: Poppins & (akan ditambah) Genty di `assets/fonts/`
