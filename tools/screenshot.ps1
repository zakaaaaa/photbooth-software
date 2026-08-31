# ============================================================================
# Screenshot jendela aplikasi Flutter ke PNG.
#
# Dipakai untuk menilai tata letak dari jarak jauh: jalankan
# lib/main_layout_preview.dart, lalu potret jendelanya dan kirim gambarnya.
#
# Jalankan:
#   powershell -ExecutionPolicy Bypass -File tools\screenshot.ps1
#   powershell ... -File tools\screenshot.ps1 -Out C:\tmp\layout.png -ProcessName photobooth_app
# ============================================================================

param(
    [string] $ProcessName = 'photobooth_app',
    [string] $Out = "$env:TEMP\layout_preview.png",
    [int]    $DelaySeconds = 0
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

# PowerShell tidak DPI-aware secara bawaan. Tanpa ini, pada layar berskala
# 200% koordinat & tangkapan layar dihitung di ruang "virtual" 1440x900
# sehingga hasilnya buram. Dengan DPI-aware kita mendapat piksel fisik penuh.
Add-Type -Namespace Win -Name Dpi -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
[DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
[DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
[DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr hWnd, IntPtr hdcBlt, uint nFlags);
public struct RECT { public int Left, Top, Right, Bottom; }
'@
[void][Win.Dpi]::SetProcessDPIAware()

if ($DelaySeconds -gt 0) { Start-Sleep -Seconds $DelaySeconds }

$proc = Get-Process -Name $ProcessName -ErrorAction SilentlyContinue |
        Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
if (-not $proc) { throw "Jendela '$ProcessName' tidak ditemukan. Aplikasinya sudah jalan?" }

$h = $proc.MainWindowHandle
if ([Win.Dpi]::IsIconic($h)) { [void][Win.Dpi]::ShowWindow($h, 9) } # SW_RESTORE
[void][Win.Dpi]::SetForegroundWindow($h)
Start-Sleep -Milliseconds 600   # beri waktu jendela naik & selesai menggambar

$r = New-Object Win.Dpi+RECT
if (-not [Win.Dpi]::GetWindowRect($h, [ref]$r)) { throw "GetWindowRect gagal." }
$w = $r.Right - $r.Left
$hgt = $r.Bottom - $r.Top
if ($w -le 0 -or $hgt -le 0) { throw "Ukuran jendela tidak masuk akal: ${w}x${hgt}" }

# PrintWindow meminta jendela MENGGAMBAR DIRINYA ke bitmap kita, jadi hasilnya
# bersih walau ada jendela lain / panel Windows yang menutupi. CopyFromScreen
# hanya memotret wilayah layar — pernah menghasilkan tangkapan berisi Quick
# Settings dan jendela lain yang kebetulan di atasnya.
# Flag 2 = PW_RENDERFULLCONTENT, wajib untuk jendela ber-GPU seperti Flutter.
$bmp = New-Object System.Drawing.Bitmap $w, $hgt
$g = [System.Drawing.Graphics]::FromImage($bmp)
$hdc = $g.GetHdc()
$printed = [Win.Dpi]::PrintWindow($h, $hdc, 2)
$g.ReleaseHdc($hdc)
$g.Dispose()

# Kalau PrintWindow gagal (bitmap polos), mundur ke tangkapan layar biasa
# setelah memaksa jendela ke depan.
[int]$midX = $w / 2
[int]$midY = $hgt / 2
[int]$rightX = $w - 10
[int]$botY = $hgt - 10
[int]$thirdX = $w / 3

$c0 = $bmp.GetPixel($midX, $midY)
$samples = @(
    $bmp.GetPixel(10, 10),
    $bmp.GetPixel($rightX, 10),
    $bmp.GetPixel(10, $botY),
    $bmp.GetPixel($thirdX, $midY)
)
$blank = $true
foreach ($c in $samples) {
    if ($c.ToArgb() -ne $c0.ToArgb()) { $blank = $false; break }
}
if (-not $printed -or $blank) {
    Write-Warning "PrintWindow tidak menghasilkan gambar; memakai tangkapan layar biasa."
    [void][Win.Dpi]::SetForegroundWindow($h)
    Start-Sleep -Milliseconds 800
    $g2 = [System.Drawing.Graphics]::FromImage($bmp)
    $g2.CopyFromScreen($r.Left, $r.Top, 0, 0, (New-Object System.Drawing.Size($w, $hgt)))
    $g2.Dispose()
}

$dir = Split-Path -Parent $Out
if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
$bmp.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()

"tersimpan: $Out  (${w}x${hgt} piksel)"
