<#
.SYNOPSIS
  Menyetel default driver printer photobooth ke profil cetak foto 4R.

.DESCRIPTION
  Media type, kualitas cetak, dan borderless TIDAK BISA diatur dari sisi
  Flutter. package:printing di Windows hanya mengisi DEVMODE untuk orientasi
  dan ukuran kertas (windows/print_job.cpp), dan dengan usePrinterSettings:true
  ia mengirim dm = nullptr sehingga Windows memakai DEFAULT DRIVER apa adanya.
  Jadi satu-satunya tempat menyetel profil cetak adalah default printer di
  mesin ini — itulah gunanya script ini.

  Diukur pada mesin photobooth 2026-08-26, default pabrik L3210 adalah
  Letter / Plain / 720dpi / borderless None. Halaman PDF 4x6 yang dikirim app
  jadi di-fit ke lembar Letter dengan profil tinta kertas biasa.

  Borderless BARU muncul di capabilities setelah PageMediaSize = 4x6;
  saat masih Letter satu-satunya opsi adalah psk:None.

.PARAMETER PrinterName
  Nama printer. Default mencari printer pertama yang cocok dengan -Match.

.PARAMETER Restore
  Kembalikan setelan dari file backup yang dibuat run sebelumnya.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File tools\setup-printer.ps1
  powershell -ExecutionPolicy Bypass -File tools\setup-printer.ps1 -Restore
#>
[CmdletBinding()]
param(
  [string] $PrinterName,
  [string] $Match = 'epson',
  [ValidateSet('Glossy','EpsonGlossy','Matte','Plain')]
  [string] $MediaType = 'Glossy',
  [switch] $Borderless = $true,
  [switch] $NoBorderless,
  [switch] $Restore
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Printing

$backupDir  = Join-Path $env:LOCALAPPDATA 'Photobooth\printer-backup'
$psfNs      = 'http://schemas.microsoft.com/windows/2003/08/printing/printschemaframework'

function Resolve-Printer {
  param([string] $Name, [string] $Keyword)
  if ($Name) { return $Name }
  $cands = Get-Printer | Where-Object {
    $_.Name -like "*$Keyword*" -and $_.PortName -notmatch '^(PORTPROMPT|nul):'
  }
  if (-not $cands) { throw "Tidak ada printer fisik yang cocok dengan '$Keyword'. Jalankan Get-Printer untuk melihat daftarnya." }
  return @($cands)[0].Name
}

function Get-DefaultTicketDoc {
  param([string] $Name)
  $server = New-Object System.Printing.PrintServer
  $q = New-Object System.Printing.PrintQueue($server, $Name)
  $doc = New-Object System.Xml.XmlDocument
  $doc.Load($q.DefaultPrintTicket.GetXmlStream())
  $q.Dispose()
  return $doc
}

# Setel satu Feature di PrintTicket. Kalau Feature-nya belum ada di ticket
# (driver hanya menuliskan yang pernah diubah), Feature-nya dibuat baru.
function Set-TicketFeature {
  param([System.Xml.XmlDocument] $Doc, [string] $Feature, [string] $Option)
  $ns = New-Object System.Xml.XmlNamespaceManager($Doc.NameTable)
  $ns.AddNamespace('psf', $psfNs)
  $node = $Doc.SelectSingleNode("//psf:Feature[@name='$Feature']", $ns)
  if ($node) {
    $opt = $node.SelectSingleNode('psf:Option', $ns)
    if ($opt) { $opt.SetAttribute('name', $Option); return }
    $node.RemoveAll() | Out-Null
    $node.SetAttribute('name', $Feature)
  } else {
    $node = $Doc.CreateElement('psf', 'Feature', $psfNs)
    $node.SetAttribute('name', $Feature)
    $Doc.DocumentElement.AppendChild($node) | Out-Null
  }
  $opt = $Doc.CreateElement('psf', 'Option', $psfNs)
  $opt.SetAttribute('name', $Option)
  $node.AppendChild($opt) | Out-Null
}

function Show-Ticket {
  param([string] $Name, [string] $Label)
  $server = New-Object System.Printing.PrintServer
  $q = New-Object System.Printing.PrintQueue($server, $Name)
  $t = $q.DefaultPrintTicket
  Write-Host ""
  Write-Host "  $Label" -ForegroundColor Cyan
  Write-Host ("    PageMediaSize  : {0}" -f $t.PageMediaSize)
  Write-Host ("    PageMediaType  : {0}" -f $t.PageMediaType)
  Write-Host ("    PageBorderless : {0}" -f $t.PageBorderless)
  Write-Host ("    PageResolution : {0}" -f $t.PageResolution)
  Write-Host ("    OutputColor    : {0}" -f $t.OutputColor)
  Write-Host ("    Orientation    : {0}" -f $t.PageOrientation)
  $q.Dispose()
}

$printer = Resolve-Printer -Name $PrinterName -Keyword $Match
Write-Host "Printer target: $printer" -ForegroundColor Yellow

$backupFile = Join-Path $backupDir ("{0}.printticket.xml" -f ($printer -replace '[^\w\-]', '_'))

# ---------------- RESTORE ----------------
if ($Restore) {
  if (-not (Test-Path $backupFile)) { throw "Tidak ada backup di $backupFile" }
  Set-PrintConfiguration -PrinterName $printer -PrintTicketXml (Get-Content $backupFile -Raw)
  Write-Host "Setelan dikembalikan dari $backupFile" -ForegroundColor Green
  Show-Ticket -Name $printer -Label 'Setelah restore:'
  return
}

# ---------------- BACKUP ----------------
if (-not (Test-Path $backupDir)) { New-Item -ItemType Directory -Force $backupDir | Out-Null }
if (-not (Test-Path $backupFile)) {
  (Get-DefaultTicketDoc -Name $printer).OuterXml | Out-File $backupFile -Encoding utf8
  Write-Host "Backup setelan asli -> $backupFile" -ForegroundColor DarkGray
} else {
  Write-Host "Backup sudah ada (setelan asli tetap terjaga) -> $backupFile" -ForegroundColor DarkGray
}

Show-Ticket -Name $printer -Label 'SEBELUM:'

# ---------------- APPLY ----------------
# Nama opsi media diambil dari capabilities L3210 yang sudah diverifikasi.
# EpsonPhotoPaperGlossy dipakai hanya untuk kertas Epson asli; kertas glossy
# merek lain lebih aman di PhotographicHighGloss (profil tinta lebih netral,
# tidak over-ink).
$mediaOption = switch ($MediaType) {
  'EpsonGlossy' { 'ns0000:EpsonPhotoPaperGlossy' }
  'Glossy'      { 'psk:PhotographicHighGloss' }
  'Matte'       { 'psk:PhotographicMatte' }
  'Plain'       { 'psk:Plain' }
}
$wantBorderless = -not $NoBorderless

$doc = Get-DefaultTicketDoc -Name $printer

# Urutan penting: 4x6 dulu, karena psk:Borderless baru valid setelah itu.
Set-TicketFeature $doc 'psk:PageMediaSize'          'ns0000:Fullsize4x6'
Set-TicketFeature $doc 'psk:PageOrientation'        'psk:Portrait'
Set-TicketFeature $doc 'psk:PageMediaType'          $mediaOption
Set-TicketFeature $doc 'psk:PageOutputColor'        'psk:Color'
Set-TicketFeature $doc 'psk:PageOutputQuality'      'ns0000:HighQuality'
Set-TicketFeature $doc 'psk:PageResolution'         'ns0000:Quality'
Set-TicketFeature $doc 'psk:PageBorderless'         $(if ($wantBorderless) { 'psk:Borderless' } else { 'psk:None' })
# psk:System, BUKAN psk:Driver. Diuji 2026-08-26: driver L3210 menolak
# 'psk:Driver' TANPA memberi error dan menjatuhkannya ke 'psk:None' —
# manajemen warna jadi MATI, RGB dikirim mentah ke tinta tanpa transformasi
# sRGB. Gejalanya foto tercetak datar/pucat sementara warna blok pekat
# (merah/biru frame) tetap terlihat benar karena dekat primer tinta.
# Itulah sebabnya blok VERIFIKASI di bawah ada: penolakan di sini senyap.
Set-TicketFeature $doc 'psk:PageColorManagement'    'psk:System'
Set-TicketFeature $doc 'psk:PageICMRenderingIntent' 'psk:Photographs'
# Auto-retouch Epson mengubah warna kulit tanpa bisa diprediksi -> matikan,
# supaya hasil cetak sama dengan preview di layar.
Set-TicketFeature $doc 'ns0000:PageFixRedEye'       'psk:Off'
Set-TicketFeature $doc 'psk:DocumentCollate'        'psk:Uncollated'

Set-PrintConfiguration -PrinterName $printer -PrintTicketXml $doc.OuterXml

# ---------------- VERIFIKASI ----------------
# WAJIB. Driver bisa menolak sebuah opsi TANPA melempar error dan diam-diam
# menggantinya dengan nilai lain. Kejadian nyata: 'psk:Driver' pada
# PageColorManagement jatuh ke 'psk:None' -> manajemen warna mati total dan
# tidak ada satu pun pesan yang muncul. Tanpa baca-balik, itu lolos.
$expected = [ordered]@{
  'psk:PageMediaSize'          = 'ns0000:Fullsize4x6'
  'psk:PageOrientation'        = 'psk:Portrait'
  'psk:PageMediaType'          = $mediaOption
  'psk:PageOutputColor'        = 'psk:Color'
  'psk:PageOutputQuality'      = 'ns0000:HighQuality'
  'psk:PageBorderless'         = $(if ($wantBorderless) { 'psk:Borderless' } else { 'psk:None' })
  'psk:PageColorManagement'    = 'psk:System'
  'psk:PageICMRenderingIntent' = 'psk:Photographs'
  'ns0000:PageFixRedEye'       = 'psk:Off'
}
# PageResolution sengaja tidak diverifikasi: driver Epson menyelaraskannya
# sendiri dengan PageOutputQuality (minta ns0000:Quality -> jadi
# ns0000:HighQuality). Itu perilaku benar, bukan penolakan.

$after = Get-DefaultTicketDoc -Name $printer
$ans = New-Object System.Xml.XmlNamespaceManager($after.NameTable)
$ans.AddNamespace('psf', $psfNs)

Write-Host ""
Write-Host "  VERIFIKASI (baca-balik dari driver)" -ForegroundColor Cyan
$failed = @()
foreach ($k in $expected.Keys) {
  $node = $after.SelectSingleNode("//psf:Feature[@name='$k']/psf:Option", $ans)
  $got = if ($node) { $node.name } else { '(tidak ada)' }
  if ($got -eq $expected[$k]) {
    Write-Host ("    OK      {0,-30} = {1}" -f $k, $got) -ForegroundColor DarkGreen
  } else {
    Write-Host ("    DITOLAK {0,-30} minta {1}, jadi {2}" -f $k, $expected[$k], $got) -ForegroundColor Red
    $failed += $k
  }
}

Show-Ticket -Name $printer -Label 'SESUDAH:'
Write-Host ""
if ($failed.Count -gt 0) {
  Write-Host ("$($failed.Count) setelan DITOLAK driver: " + ($failed -join ', ')) -ForegroundColor Red
  Write-Host "Hasil cetak belum tentu benar. Periksa nilainya di Printing Preferences." -ForegroundColor Red
} else {
  Write-Host "Semua setelan terverifikasi diterima driver." -ForegroundColor Green
}
Write-Host "Kembalikan kapan saja dengan: -Restore" -ForegroundColor Green
