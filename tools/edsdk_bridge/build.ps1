# ============================================================================
# Build edsdk_bridge.exe (x86) dan salin runtime EDSDK ke assets/bin/.
#
# Dipakai csc.exe dari .NET Framework 4 yang SELALU ada di Windows, jadi
# tidak perlu memasang .NET SDK / Visual Studio project apa pun.
#
# WAJIB /platform:x86 — EDSDK.dll yang kita pakai adalah 32-bit.
#
# Jalankan:  powershell -ExecutionPolicy Bypass -File tools\edsdk_bridge\build.ps1
# ============================================================================

$ErrorActionPreference = 'Stop'

$here    = Split-Path -Parent $MyInvocation.MyCommand.Path
$root    = Resolve-Path (Join-Path $here '..\..')
$outDir  = Join-Path $root 'assets\bin'
$outExe  = Join-Path $outDir 'edsdk_bridge.exe'

$csc = 'C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path $csc)) { $csc = 'C:\Windows\Microsoft.NET\Framework\v4.0.30319\csc.exe' }
if (-not (Test-Path $csc)) { throw "csc.exe (.NET Framework 4) tidak ditemukan." }

if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Force $outDir | Out-Null }

$sources = @(
    (Join-Path $here 'Edsdk.cs'),
    (Join-Path $here 'Program.cs')
)

Write-Host "Compiling edsdk_bridge.exe (x86)..." -ForegroundColor Cyan
& $csc /nologo /target:exe /platform:x86 /optimize+ /langversion:5 `
       /out:"$outExe" `
       /r:System.dll /r:System.Core.dll `
       $sources
if ($LASTEXITCODE -ne 0) { throw "Kompilasi gagal (exit $LASTEXITCODE)" }

# ---- Runtime EDSDK ----------------------------------------------------------
# edsdk_bridge.exe mencari EDSDK.dll di folder exe-nya sendiri (aturan
# pencarian DLL Windows), jadi kedua file ini harus bersebelahan.
$dcc = 'C:\Program Files (x86)\digiCamControl'
foreach ($dll in @('EDSDK.dll', 'EdsImage.dll')) {
    $src = Join-Path $dcc $dll
    $dst = Join-Path $outDir $dll
    if (Test-Path $src) {
        if (-not (Test-Path $dst) -or (Get-Item $src).Length -ne (Get-Item $dst).Length) {
            Copy-Item $src $dst -Force
            Write-Host "  disalin: $dll" -ForegroundColor DarkGray
        }
    } elseif (-not (Test-Path $dst)) {
        Write-Warning "$dll tidak ditemukan di $dcc dan belum ada di $outDir."
    }
}

Write-Host "OK -> $outExe" -ForegroundColor Green
Get-Item $outExe | Select-Object Name, Length, LastWriteTime | Format-List
