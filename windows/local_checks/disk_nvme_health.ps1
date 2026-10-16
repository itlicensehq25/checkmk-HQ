# ==========================================================
# disk_nvme_health.ps1 - Checkmk Local Check (Windows)
# Menampilkan: tipe disk (NVMe / SSD SATA / HDD SATA), status kesehatan,
#              suhu, dan keausan - untuk SEMUA disk internal.
# Urutan sumber data (disk yang sudah terbaca tidak diambil lagi):
#   1. smartctl            (akurat; NVMe dan SATA)
#   2. CrystalDiskInfo     (dibaca dari diskinfo.txt hasil Scheduled Task)
#   3. Windows             (cadangan, kurang akurat, tanpa grafik)
# Service: "Storage_Health" (disk ke-2 dst: "Storage_Health 2", "Storage_Health 3")
# Disk NVMe selalu urutan pertama.
# Letakkan di: C:\ProgramData\checkmk\agent\local\
# ==========================================================

$ErrorActionPreference = 'SilentlyContinue'

# ---------- Pengaturan ----------
$WarnTemp       = 60    # derajat C
$CritTemp       = 70
$WarnUsed       = 10    # % keausan
$CritUsed       = 20
$ShowMetrics    = $false # false = tanpa grafik/metrik (tampilan bersih); true = ada grafik suhu & keausan di Checkmk
$CdiFile        = 'C:\ProgramData\checkmk\agent\log_custom\diskinfo.txt'
$CdiMaxAgeHours = 8     # data CrystalDiskInfo lebih tua dari ini dianggap kedaluwarsa (jadwal 6 jam)
# --------------------------------

function Write-Check {
    param([int]$State, [string]$Name, [string]$Metrics, [string]$Text)
    if ([string]::IsNullOrWhiteSpace($Metrics)) { $Metrics = '-' }
    Write-Output ('{0} "{1}" {2} {3}' -f $State, $Name, $Metrics, $Text)
}

function Get-NormName {
    param([string]$s)
    if (-not $s) { return '' }
    return (($s -replace '[^A-Za-z0-9]', '').ToLower())
}

# Apakah disk dengan model ini sudah ada di daftar $disks?
function Test-Known {
    param([string]$Model)
    $y = Get-NormName $Model
    if (-not $y) { return $false }
    foreach ($d in $disks) {
        $x = Get-NormName $d.Model
        if ($x -and ($x.Contains($y) -or $y.Contains($x))) { return $true }
    }
    return $false
}

$disks = @()
$note  = ''
$seenDisks = @{}

# ---------- 1. smartctl (NVMe dan SATA) ----------
$smartctl = $null
$cmd = Get-Command smartctl.exe -ErrorAction SilentlyContinue
if ($cmd) { $smartctl = $cmd.Source }
if (-not $smartctl) {
    foreach ($p in @(
        'C:\Program Files\smartmontools\bin\smartctl.exe',
        'C:\Program Files (x86)\smartmontools\bin\smartctl.exe'
    )) {
        if (Test-Path $p) { $smartctl = $p; break }
    }
}

if ($smartctl) {
    $devices = @()
    try {
        $scan = (& $smartctl --scan -j 2>$null | Out-String) | ConvertFrom-Json
        if ($scan -and $scan.devices) { $devices = @($scan.devices) }
    } catch {}

    foreach ($d in $devices) {
        $json = $null
        try { $json = (& $smartctl -j -a $d.name -d $d.type 2>$null | Out-String) | ConvertFrom-Json } catch {}
        if (-not $json) { continue }

        $model = $json.model_name
        if (-not $model) { $model = 'Disk' }

        # Lewati disk yang sama jika smartctl memindainya lebih dari sekali
        # (mis. lewat /dev/sda dan jalur lain seperti csmi/sat)
        $serial = [string]$json.serial_number
        if ($serial) { $dupKey = "$model|$serial" } else { $dupKey = $model }
        if ($seenDisks.ContainsKey($dupKey)) { continue }
        $seenDisks[$dupKey] = $true

        $nvmeLog  = $json.nvme_smart_health_information_log
        $ataTable = @($json.ata_smart_attributes.table)

        if ($nvmeLog) {
            # ----- NVMe -----
            $health = 'Healthy'
            if ([int]$nvmeLog.critical_warning -ne 0) { $health = 'Warning' }
            if ($json.smart_status.passed -eq $false) { $health = 'Unhealthy' }

            $wear = [int]$nvmeLog.percentage_used
            $pct  = [math]::Max(0, 100 - $wear)

            $disks += [pscustomobject]@{
                Model    = $model
                Type     = 'NVMe'
                Health   = $health
                Display  = "$health ($pct%)"
                Temp     = [int]$nvmeLog.temperature
                Wear     = $wear
                Accurate = $true
                Source   = 'smartctl'
            }
        }
        elseif ($ataTable.Count -gt 0) {
            # ----- SATA (SSD / HDD) -----
            $isSsd = $true
            if ($null -ne $json.rotation_rate -and [int]$json.rotation_rate -gt 0) { $isSsd = $false }

            # Suhu
            $temp = $null
            if ($null -ne $json.temperature -and $null -ne $json.temperature.current) {
                $temp = [int]$json.temperature.current
            } else {
                foreach ($a in $ataTable) {
                    if ($a.name -match 'Temperature' -and $null -ne $a.raw) {
                        $temp = [int]($a.raw.value -band 255); break
                    }
                }
            }

            # Sisa umur SSD (nilai ternormalisasi = persen sisa)
            $remain = $null
            if ($isSsd) {
                foreach ($a in $ataTable) {
                    if ($a.name -match 'Wear_Leveling_Count|Media_Wearout_Indicator|SSD_Life_Left|Percent_Lifetime_Remain|Remaining_Lifetime_Perc') {
                        $v = [int]$a.value
                        if ($v -gt 0 -and $v -le 100) { $remain = $v; break }
                    }
                }
            }

            # Status
            $health = 'Healthy'
            foreach ($a in $ataTable) {
                if (($a.id -eq 5 -or $a.id -eq 197 -or $a.id -eq 198) -and $null -ne $a.raw -and [long]$a.raw.value -gt 0) {
                    $health = 'Warning'
                }
            }
            if ($json.smart_status.passed -eq $false) { $health = 'Unhealthy' }

            $wear    = $null
            $display = $health
            if ($null -ne $remain) {
                $wear    = 100 - $remain
                $display = "$health ($remain%)"
            }

            $tipe = 'HDD SATA'
            if ($isSsd) { $tipe = 'SSD SATA' }

            $disks += [pscustomobject]@{
                Model    = $model
                Type     = $tipe
                Health   = $health
                Display  = $display
                Temp     = $temp
                Wear     = $wear
                Accurate = $true
                Source   = 'smartctl'
            }
        }
    }
}

# ---------- 2. CrystalDiskInfo (diskinfo.txt) ----------
if (Test-Path $CdiFile) {
    $ageHours = ((Get-Date) - (Get-Item $CdiFile).LastWriteTime).TotalHours
    if ($ageHours -gt $CdiMaxAgeHours) {
        $note = ' [data CrystalDiskInfo kedaluwarsa, cek Scheduled Task Checkmk_CrystalDiskInfo]'
    } else {
        $cdiList = @()
        $cur = $null
        foreach ($line in (Get-Content $CdiFile)) {
            if ($line -match '^\s*Model\s*:\s*(.+?)\s*$') {
                if ($cur) { $cdiList += $cur }
                $cur = [pscustomobject]@{ Model = $Matches[1]; Interface = ''; Rotation = ''; Temp = $null; Word = ''; Pct = $null }
                continue
            }
            if (-not $cur) { continue }
            if ($line -match '^\s*Interface\s*:\s*(.+?)\s*$') {
                $cur.Interface = $Matches[1]
            } elseif ($line -match '^\s*Rotation Rate\s*:\s*(.+?)\s*$') {
                $cur.Rotation = $Matches[1]
            } elseif ($line -match '^\s*Temperature\s*:\s*(-?\d+)\s*C') {
                $cur.Temp = [int]$Matches[1]
            } elseif ($line -match '^\s*Health Status\s*:\s*([A-Za-z]+)(?:\s*\((\d+)\s*%\))?') {
                $cur.Word = $Matches[1]
                if ($Matches[2]) { $cur.Pct = [int]$Matches[2] }
            }
        }
        if ($cur) { $cdiList += $cur }

        foreach ($c in $cdiList) {
            # Hanya disk internal NVMe / SATA (USB dan lainnya dilewati)
            if ($c.Interface -notmatch 'NVM|ATA') { continue }
            if (Test-Known $c.Model) { continue }

            $tipe = 'SATA'
            if ($c.Interface -match 'NVM') { $tipe = 'NVMe' }
            elseif ($c.Rotation -match 'SSD|^-+') { $tipe = 'SSD SATA' }
            elseif ($c.Rotation -match 'RPM')     { $tipe = 'HDD SATA' }
            elseif ($null -ne $c.Pct)             { $tipe = 'SSD SATA' }

            $health = 'Unknown'
            if ($c.Word -eq 'Good')    { $health = 'Healthy' }
            if ($c.Word -eq 'Caution') { $health = 'Warning' }
            if ($c.Word -eq 'Bad')     { $health = 'Unhealthy' }

            $wear = $null
            $display = $c.Word
            if ($null -ne $c.Pct) {
                $wear = [math]::Max(0, 100 - $c.Pct)
                $display = "$($c.Word) ($($c.Pct)%)"
            }
            if (-not $display) { $display = 'Unknown' }

            $disks += [pscustomobject]@{
                Model    = $c.Model
                Type     = $tipe
                Health   = $health
                Display  = $display
                Temp     = $c.Temp
                Wear     = $wear
                Accurate = $true
                Source   = 'CrystalDiskInfo'
            }
        }
    }
}

# ---------- 3. Cadangan: data dari Windows ----------
$pds = @(Get-PhysicalDisk | Where-Object { @('NVMe', 'SATA', 'ATA', 'SAS', 'SCSI') -contains [string]$_.BusType })
$winNvme  = @($pds | Where-Object { [string]$_.BusType -eq 'NVMe' }).Count
$winOther = $pds.Count - $winNvme

foreach ($pd in $pds) {
    $isNvme = ([string]$pd.BusType -eq 'NVMe')

    # Jika jumlah disk sejenis sudah terbaca dari sumber 1/2, lewati
    $have = @($disks | Where-Object { ($_.Type -eq 'NVMe') -eq $isNvme }).Count
    $need = $winOther
    if ($isNvme) { $need = $winNvme }
    if ($have -ge $need) { continue }
    if (Test-Known $pd.FriendlyName) { continue }

    $rc = $null
    try { $rc = $pd | Get-StorageReliabilityCounter } catch {}

    $temp = $null
    $wear = $null
    if ($rc) {
        if ($null -ne $rc.Temperature -and [int]$rc.Temperature -gt 0) { $temp = [int]$rc.Temperature }
        if ($null -ne $rc.Wear) { $wear = [int]$rc.Wear }
    }

    $tipe = 'NVMe'
    if (-not $isNvme) {
        if ([string]$pd.MediaType -eq 'SSD') { $tipe = 'SSD SATA' }
        elseif ([string]$pd.MediaType -eq 'HDD') { $tipe = 'HDD SATA' }
        else { $tipe = 'SATA' }
    }

    $model = $pd.FriendlyName
    if (-not $model) { $model = $tipe }
    $health = [string]$pd.HealthStatus
    if (-not $health) { $health = 'Unknown' }

    $disks += [pscustomobject]@{
        Model    = $model
        Type     = $tipe
        Health   = $health
        Display  = $health
        Temp     = $temp
        Wear     = $wear
        Accurate = $false
        Source   = 'Windows'
    }
}

if ($disks.Count -eq 0) {
    Write-Check 0 'Storage_Health' '-' ('Tidak ada disk terdeteksi' + $note)
    exit
}

# NVMe di urutan pertama
$disks = @($disks | Sort-Object @{ Expression = { if ($_.Type -eq 'NVMe') { 0 } else { 1 } } }, Model)

# ---------- Output ----------
$i = 0
foreach ($dk in $disks) {
    $i++

    $state = 0
    if ($dk.Health -eq 'Warning')   { $state = 1 }
    if ($dk.Health -eq 'Unhealthy') { $state = 2 }

    if ($dk.Accurate) {
        if ($null -ne $dk.Temp) {
            if ($dk.Temp -ge $CritTemp) { $state = 2 }
            elseif ($dk.Temp -ge $WarnTemp -and $state -lt 1) { $state = 1 }
        }
        if ($null -ne $dk.Wear) {
            if ($dk.Wear -ge $CritUsed) { $state = 2 }
            elseif ($dk.Wear -ge $WarnUsed -and $state -lt 1) { $state = 1 }
        }
    }

    $tempText = 'tidak tersedia'
    $wearText = 'tidak tersedia'
    $metricList = @()
    if ($null -ne $dk.Temp) {
        $tempText = "$($dk.Temp) C"
        $metricList += "temp=$($dk.Temp);$WarnTemp;$CritTemp"
    }
    if ($null -ne $dk.Wear) {
        $wearText = "$($dk.Wear)%"
        $metricList += "wear=$($dk.Wear);$WarnUsed;$CritUsed;0;100"
    }

    # Metrik hanya untuk data akurat; data Windows tidak dibuatkan grafik.
    $metrics = '-'
    if ($ShowMetrics -and $dk.Accurate -and $metricList.Count -gt 0) { $metrics = $metricList -join '|' }

    $name = 'Storage_Health'
    if ($i -gt 1) { $name = "Storage_Health $i" }

    $text = "$($dk.Model) | Tipe: $($dk.Type) | Status: $($dk.Display) | Suhu: $tempText"
    if ($dk.Type -ne 'HDD SATA') { $text += " | Keausan: $wearText" }
    if ($dk.Source -ne 'smartctl') { $text += " [sumber: $($dk.Source)]" }
    if ($dk.Source -eq 'Windows') { $text += $note }

    Write-Check $state $name $metrics $text
}

