# ==========================================================
# network_local.ps1 - Checkmk Local Check (Windows)
# Cek network LOKAL:
#   1. Network Link        : adapter fisik berstatus Up
#   2. Network Local <ip>  : ping ke target lokal (default 192.168.9.1)
#   3. Network Disconnect  : jumlah kejadian putus dalam N jam terakhir
# Letakkan di: C:\ProgramData\checkmk\agent\local\
# ==========================================================

$ErrorActionPreference = 'SilentlyContinue'

# ---------- Pengaturan ----------
$LocalHosts    = @('192.168.9.1')   # target ping jaringan lokal (boleh lebih dari satu)
$LookbackHours = 24          # rentang riwayat putus (jam)
$PingCount     = 4           # jumlah ping per target
$WarnLoss      = 25          # % packet loss -> WARN
$CritLoss      = 50          # % packet loss -> CRIT
$WarnLatency   = 100         # ms -> WARN
$CritLatency   = 300         # ms -> CRIT
$WarnDisc      = 1           # jumlah putus -> WARN
$CritDisc      = 5           # jumlah putus -> CRIT
# --------------------------------

function Write-Check {
    param([int]$State, [string]$Name, [string]$Metrics, [string]$Text)
    if ([string]::IsNullOrWhiteSpace($Metrics)) { $Metrics = '-' }
    Write-Output ('{0} "{1}" {2} {3}' -f $State, $Name, $Metrics, $Text)
}

function Get-PingStats {
    param([string]$Target, [int]$Count = 4)
    $ping  = New-Object System.Net.NetworkInformation.Ping
    $times = @()
    for ($i = 0; $i -lt $Count; $i++) {
        try {
            $r = $ping.Send($Target, 1000)
            if ($r.Status -eq 'Success') { $times += [int]$r.RoundtripTime }
        } catch {}
        Start-Sleep -Milliseconds 200
    }
    $recv = $times.Count
    $avg = 0; $max = 0
    if ($recv -gt 0) {
        $avg = [math]::Round(($times | Measure-Object -Average).Average)
        $max = ($times | Measure-Object -Maximum).Maximum
    }
    [pscustomobject]@{
        Sent = $Count
        Recv = $recv
        Loss = [math]::Round((($Count - $recv) / $Count) * 100)
        Avg  = $avg
        Max  = $max
    }
}

function Get-PingState {
    param($Stats)
    if ($Stats.Recv -eq 0) { return 2 }
    if ($Stats.Loss -ge $CritLoss -or $Stats.Avg -ge $CritLatency) { return 2 }
    if ($Stats.Loss -ge $WarnLoss -or $Stats.Avg -ge $WarnLatency) { return 1 }
    return 0
}

# ---------- 1. Link adapter ----------
$adapters = @(Get-NetAdapter -Physical | Where-Object { $_.Status -eq 'Up' })
if ($adapters.Count -gt 0) {
    $desc = ($adapters | ForEach-Object { '{0} ({1})' -f $_.Name, $_.LinkSpeed }) -join ', '
    Write-Check 0 'Network Link' "adapters_up=$($adapters.Count)" "Adapter aktif: $desc"
} else {
    Write-Check 2 'Network Link' 'adapters_up=0' 'Tidak ada adapter fisik yang Up (kabel/WiFi terputus)'
}

# ---------- 2. Ping target lokal ----------
foreach ($t in $LocalHosts) {
    $s = Get-PingStats -Target $t -Count $PingCount
    $state = Get-PingState $s
    $metrics = "loss=$($s.Loss);$WarnLoss;$CritLoss;0;100|rtt=$($s.Avg);$WarnLatency;$CritLatency"
    $name = "Network Local $t"
    if ($s.Recv -eq 0) {
        Write-Check 2 $name $metrics "$t tidak merespon (jaringan lokal bermasalah)"
    } else {
        Write-Check $state $name $metrics "$t : loss $($s.Loss)%, rata-rata $($s.Avg) ms, maks $($s.Max) ms"
    }
}

# ---------- 3. Riwayat putus ----------
# Event 10001 = network disconnected, 10000 = connected
# Log: Microsoft-Windows-NetworkProfile/Operational
$start = (Get-Date).AddHours(-$LookbackHours)
$log = 'Microsoft-Windows-NetworkProfile/Operational'

if ($null -eq (Get-WinEvent -ListLog $log -ErrorAction SilentlyContinue)) {
    Write-Check 3 'Network Disconnect' '-' "Log $log tidak tersedia"
} else {
    $disc = @(Get-WinEvent -FilterHashtable @{ LogName = $log; Id = 10001; StartTime = $start } -ErrorAction SilentlyContinue)
    $count = $disc.Count
    $state = 0
    if ($count -ge $CritDisc) { $state = 2 }
    elseif ($count -ge $WarnDisc) { $state = 1 }

    if ($count -gt 0) {
        $last = ($disc | Sort-Object TimeCreated -Descending | Select-Object -First 1).TimeCreated.ToString('yyyy-MM-dd HH:mm:ss')
        $text = "Putus $count kali dalam $LookbackHours jam terakhir, terakhir: $last"
    } else {
        $text = "Tidak ada putus dalam $LookbackHours jam terakhir"
    }
    Write-Check $state 'Network Disconnect' "disconnects=$count;$WarnDisc;$CritDisc" $text
}
