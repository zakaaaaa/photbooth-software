# ============================================================================
# Uji edsdk_bridge.exe langsung, tanpa menjalankan app Flutter.
#
# Yang diperiksa:
#   1. kamera terdeteksi & sesi USB bisa dibuka
#   2. live view mengalir  → diukur fps & ukuran frame sebenarnya
#   3. autofocus jalan
#   4. shutter menghasilkan JPEG resolusi penuh  → disimpan & dicek dimensinya
#
# Jalankan:
#   powershell -ExecutionPolicy Bypass -File tools\edsdk_bridge\test-bridge.ps1
#   powershell ... -File ...\test-bridge.ps1 -Seconds 10 -NoCapture
#
# stderr bridge (baris READY / EVENT / LOG / ERR) sengaja TIDAK di-redirect
# supaya langsung tampil di terminal ini dan tidak ada risiko pipe penuh.
# ============================================================================

param(
    [int]    $Seconds = 6,        # lama merekam live view untuk ukur fps
    [switch] $NoCapture,          # lewati uji shutter
    [switch] $WithAf,             # jepret pakai autofocus (default: non-AF)
    [string] $ExtraArgs = "",     # argumen tambahan untuk bridge, mis. "--evf-small"
    [string] $OutDir = "$env:TEMP\edsdk_test"
)

$ErrorActionPreference = 'Stop'

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$exe  = Join-Path (Resolve-Path (Join-Path $here '..\..')) 'assets\bin\edsdk_bridge.exe'
if (-not (Test-Path $exe)) { throw "edsdk_bridge.exe belum dibuild. Jalankan tools\edsdk_bridge\build.ps1 dulu." }
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Force $OutDir | Out-Null }

function Read-Exact($stream, [int]$count) {
    $buf = New-Object byte[] $count
    $off = 0
    while ($off -lt $count) {
        $n = $stream.Read($buf, $off, $count - $off)
        if ($n -le 0) { return $null }
        $off += $n
    }
    return $buf
}

function Get-JpegSize([byte[]]$b) {
    # Telusuri rantai marker JPEG sampai SOF, dengan MELOMPATI tiap segmen
    # sesuai panjangnya. Penting: foto Canon menyimpan thumbnail JPEG utuh
    # di dalam APP1/EXIF — kalau penelusuran sampai desinkron lalu "mencari
    # 0xFF berikutnya", yang ketemu adalah SOF thumbnail dan dimensinya
    # salah total. Jadi begitu desinkron, menyerah saja daripada menebak.
    $i = 2
    while ($i -lt $b.Length - 9) {
        if ($b[$i] -ne 0xFF) { return "?" }
        while ($i + 1 -lt $b.Length -and $b[$i + 1] -eq 0xFF) { $i++ }  # fill byte
        $m = $b[$i + 1]

        # Marker tanpa segmen panjang.
        if ($m -eq 0xD8 -or $m -eq 0x01 -or ($m -ge 0xD0 -and $m -le 0xD7)) { $i += 2; continue }
        # SOS/EOI: data terkompresi mulai, SOF pasti sudah lewat.
        if ($m -eq 0xDA -or $m -eq 0xD9) { return "?" }

        # WAJIB [int]: di PowerShell `-shl` pada [byte] menggeser dalam 8 bit,
        # jadi 0x02 -shl 8 menghasilkan 0, bukan 512. Tanpa cast ini yang
        # terbaca hanya byte rendah (960x640 terbaca 192x128) dan panjang
        # segmen ikut salah sehingga penelusuran desinkron.
        if ($m -ge 0xC0 -and $m -le 0xCF -and $m -ne 0xC4 -and $m -ne 0xC8 -and $m -ne 0xCC) {
            $h = ([int]$b[$i + 5] -shl 8) -bor [int]$b[$i + 6]
            $w = ([int]$b[$i + 7] -shl 8) -bor [int]$b[$i + 8]
            return "$w x $h"
        }

        $len = ([int]$b[$i + 2] -shl 8) -bor [int]$b[$i + 3]
        if ($len -lt 2) { return "?" }
        $i += 2 + $len
    }
    return "?"
}

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName               = $exe
$psi.Arguments              = "--wait 8 --evf-fps 30 $ExtraArgs"
$psi.UseShellExecute         = $false
$psi.RedirectStandardInput   = $true
$psi.RedirectStandardOutput  = $true
$psi.RedirectStandardError   = $false   # biar log kamera langsung terlihat

Write-Host "menjalankan: $exe $($psi.Arguments)" -ForegroundColor Cyan
$p  = [System.Diagnostics.Process]::Start($psi)
$so = $p.StandardOutput.BaseStream
$si = $p.StandardInput

try {
    Start-Sleep -Milliseconds 800
    if ($p.HasExited) { throw "bridge langsung keluar (exit $($p.ExitCode)) — lihat pesan ERR di atas." }

    $si.WriteLine("LIVEVIEW ON 30"); $si.Flush()

    $evfCount = 0; $evfBytes = 0; $firstEvf = $null
    $photo = $null
    $captureSent = $false
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $evfWindow = $Seconds

    while ($true) {
        if ($p.HasExited) { Write-Warning "bridge berhenti di tengah uji (exit $($p.ExitCode))."; break }

        $hdr = Read-Exact $so 12
        if ($null -eq $hdr) { break }
        if ($hdr[0] -ne 0x45 -or $hdr[1] -ne 0x44 -or $hdr[2] -ne 0x53 -or $hdr[3] -ne 0x31) {
            throw "magic frame tidak cocok — protokol stdout rusak."
        }
        $type = [BitConverter]::ToUInt32($hdr, 4)
        $len  = [BitConverter]::ToUInt32($hdr, 8)
        $payload = Read-Exact $so $len
        if ($null -eq $payload) { break }

        if ($type -eq 1) {
            $evfCount++; $evfBytes += $len
            if ($null -eq $firstEvf) { $firstEvf = $payload }
        } elseif ($type -eq 2) {
            $photo = $payload
            break
        }

        if (-not $captureSent -and $sw.Elapsed.TotalSeconds -ge $evfWindow) {
            $fps = [math]::Round($evfCount / $sw.Elapsed.TotalSeconds, 1)
            Write-Host ""
            Write-Host "LIVE VIEW: $evfCount frame dalam $([math]::Round($sw.Elapsed.TotalSeconds,1))s = $fps fps" -ForegroundColor Green
            Write-Host "           rata-rata $([math]::Round($evfBytes / [math]::Max($evfCount,1) / 1024, 1)) KB/frame, dimensi $(Get-JpegSize $firstEvf)"
            if ($firstEvf) {
                $f = Join-Path $OutDir 'liveview.jpg'
                [IO.File]::WriteAllBytes($f, $firstEvf)
                Write-Host "           contoh frame -> $f"
            }

            if ($NoCapture) { break }

            Write-Host ""
            Write-Host "-> AF (kunci fokus)..." -ForegroundColor Cyan
            $si.WriteLine("AF"); $si.Flush()
            Start-Sleep -Seconds 3

            Write-Host "-> CAPTURE..." -ForegroundColor Cyan
            $si.WriteLine($(if ($WithAf) { "CAPTURE AF" } else { "CAPTURE" })); $si.Flush()
            $captureSent = $true
            $sw.Restart()
        }

        if ($captureSent -and $sw.Elapsed.TotalSeconds -gt 25) {
            Write-Warning "tidak ada foto masuk dalam 25 detik."
            break
        }
    }

    if ($photo) {
        $f = Join-Path $OutDir 'capture.jpg'
        [IO.File]::WriteAllBytes($f, $photo)
        Write-Host ""
        Write-Host "FOTO: $([math]::Round($photo.Length / 1MB, 2)) MB, dimensi $(Get-JpegSize $photo)" -ForegroundColor Green
        Write-Host "      -> $f"
        Write-Host ""
        Write-Host "Kalau dimensinya sekitar 5184 x 3456, berarti 18MP penuh sudah didapat." -ForegroundColor Yellow
    } elseif (-not $NoCapture) {
        Write-Warning "tidak ada foto yang diterima."
    }
}
finally {
    try { $si.WriteLine("QUIT"); $si.Flush() } catch {}
    if (-not $p.WaitForExit(4000)) { try { $p.Kill() } catch {} }
    Write-Host ""
    Write-Host "bridge exit code: $($p.ExitCode)"
}
