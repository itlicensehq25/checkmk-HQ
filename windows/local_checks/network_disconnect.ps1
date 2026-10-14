# ==========================================================
# network_disconnect.ps1 - Checkmk Local Check (Windows)
# Riwayat network putus:
#   - Service "Network Disconnect" : jumlah putus dalam N jam terakhir
#   - Setiap kejadian PUTUS/TERSAMBUNG dicatat ke CSV:
#     C:\ProgramData\checkmk\agent\log\network_putus.csv
# Sumber: Event Log Microsoft-Windows-NetworkProfile/Operational
#   Event 10001 = putus, Event 10000 = tersambung
# Letakkan di: C:\ProgramData\checkmk\agent\local\
# ==========================================================

$ErrorActionPreference = 'SilentlyContinue'

# ---------- Pengaturan ----------
$LookbackHours = 24
$WarnDisc      = 5           # jumlah putus -> WARN
$CritDisc      = 10           # jumlah putus -> CRIT
$LogDir        = 'C:\ProgramData\checkmk\agent\log'
$CsvFile       = Join-Path $LogDir 'network_putus.csv'
$StateFile     = Join-Path $LogDir 'network_putus_state.txt'
$FirstRunDays  = 7           # saat pertama jalan, ambil riwayat sekian hari ke belakang
# --------------------------------

function Write-Check {
    param([int]$State, [string]$Name, [string]$Metrics, [string]$Text)
    if ([string]::IsNullOrWhiteSpace($Metrics)) { $Metrics = '-' }
    Write-Output ('{0} "{1}" {2} {3}' -f $State, $Name, $Metrics, $Text)
}

$logName = 'Microsoft-Windows-NetworkProfile/Operational'

if ($null -eq (Get-WinEvent -ListLog $logName -ErrorAction SilentlyContinue)) {
    Write-Check 3 'Info_Network Disconnect' '-' "Log $logName tidak tersedia"
    exit
}

# ---------- 1. Catat kejadian baru ke CSV ----------
try {
    if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }

    $lastTicks = (Get-Date).AddDays(-$FirstRunDays).Ticks
    if (Test-Path $StateFile) {
        $saved = 0L
        if ([long]::TryParse(((Get-Content $StateFile -ErrorAction SilentlyContinue) | Select-Object -First 1), [ref]$saved)) {
            $lastTicks = $saved
        }
    }

    $startTime = New-Object DateTime -ArgumentList $lastTicks
    $new = @(Get-WinEvent -FilterHashtable @{ LogName = $logName; Id = 10000, 10001; StartTime = $startTime } -ErrorAction SilentlyContinue |
        Where-Object { $_.TimeCreated.Ticks -gt $lastTicks } |
        Sort-Object TimeCreated)

    if ($new.Count -gt 0) {
        $rows = $new | ForEach-Object {
            [pscustomobject]@{
                Waktu      = $_.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss')
                PC         = $env:COMPUTERNAME
                Status     = $(if ($_.Id -eq 10001) { 'PUTUS' } else { 'TERSAMBUNG' })
                Keterangan = ($_.Message -replace '\s*\r?\n\s*', ' ').Trim()
            }
        }
        $rows | Export-Csv -Path $CsvFile -Append -NoTypeInformation -Encoding UTF8 -ErrorAction Stop
        $newest = ($new | Select-Object -Last 1).TimeCreated.Ticks
        Set-Content -Path $StateFile -Value $newest
    }
} catch {}

# ---------- 2. Service Checkmk ----------
$MaxList = 15    # jumlah kejadian putus yang ditampilkan di Details

function Format-Durasi {
    param([int]$Detik)
    if ($Detik -lt 60) { return "$Detik dtk" }
    if ($Detik -lt 3600) { return ('{0} mnt {1} dtk' -f [int][math]::Floor($Detik / 60), ($Detik % 60)) }
    return ('{0} jam {1} mnt' -f [int][math]::Floor($Detik / 3600), [int][math]::Floor(($Detik % 3600) / 60))
}

$start = (Get-Date).AddHours(-$LookbackHours)
$ev    = @(Get-WinEvent -FilterHashtable @{ LogName = $logName; Id = 10000, 10001; StartTime = $start } -ErrorAction SilentlyContinue |
    Sort-Object TimeCreated)
$disc  = @($ev | Where-Object { $_.Id -eq 10001 })
$conn  = @($ev | Where-Object { $_.Id -eq 10000 })
$count = $disc.Count

$state = 0
if ($count -ge $CritDisc) { $state = 2 }
elseif ($count -ge $WarnDisc) { $state = 1 }

$detail = ''
if ($count -gt 0) {
    $last = ($disc | Select-Object -Last 1).TimeCreated.ToString('yyyy-MM-dd HH:mm:ss')
    $text = "Putus $count kali dalam $LookbackHours jam terakhir, terakhir: $last"

    # Daftar kejadian putus (terbaru dulu) + lama sampai tersambung kembali
    $items = @($disc | Sort-Object TimeCreated -Descending | Select-Object -First $MaxList | ForEach-Object {
        $d  = $_
        $re = $conn | Where-Object { $_.TimeCreated -gt $d.TimeCreated } | Select-Object -First 1
        if ($re) {
            $dur = Format-Durasi ([int]($re.TimeCreated - $d.TimeCreated).TotalSeconds)
            '{0} putus, tersambung lagi setelah {1}' -f $d.TimeCreated.ToString('MM-dd HH:mm:ss'), $dur
        } else {
            '{0} putus, belum tercatat tersambung kembali' -f $d.TimeCreated.ToString('MM-dd HH:mm:ss')
        }
    })
    $more = ''
    if ($count -gt $MaxList) {
        $more = '\n... dan ' + ($count - $MaxList) + ' kejadian lain (lihat network_putus.csv)'
    }
    $detail = '\nDaftar putus (terbaru dulu):\n' + ($items -join '\n') + $more
} else {
    $text = "Tidak ada putus dalam $LookbackHours jam terakhir"
}
Write-Check $state 'info_Network Disconnect' "disconnects=$count;$WarnDisc;$CritDisc" ($text + $detail)
