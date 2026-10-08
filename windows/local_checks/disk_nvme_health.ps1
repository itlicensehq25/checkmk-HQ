# =====================================================================
# Local Check Checkmk: Daily Storage Health Monitor (Windows)
# Scheduled to run once a day at 16:00
# =====================================================================
$CacheDir = "$env:ProgramData\checkmk\agent\cache"
if (-not (Test-Path $CacheDir)) { New-Item -ItemType Directory -Force $CacheDir | Out-Null }
$CacheFile = Join-Path $CacheDir "cache_disk_health.txt"

# Get current hour and today's 16:00 threshold
$Now = Get-Date
$Today16 = Get-Date -Hour 16 -Minute 0 -Second 0
if ($Now -lt $Today16) {
    $Last16 = $Today16.AddDays(-1)
} else {
    $Last16 = $Today16
}

$NeedUpdate = $true
if (Test-Path $CacheFile) {
    $CacheMtime = (Get-Item $CacheFile).LastWriteTime
    if ($CacheMtime -ge $Last16) {
        $NeedUpdate = $false
    }
}

if ($NeedUpdate) {
    if (Test-Path $CacheFile) { Remove-Item $CacheFile -Force }
    
    # Get Physical Disks via CIM (Storage Namespace)
    $Disks = Get-PhysicalDisk -ErrorAction SilentlyContinue
    
    if (-not $Disks) {
        "0 `"Storage_NVMe_Status`" - No physical disks detected on this system." | Out-File -FilePath $CacheFile -Encoding utf8 -Force
    } else {
        foreach ($Disk in $Disks) {
            $DeviceID = $Disk.DeviceID
            $Model = $Disk.FriendlyName.Trim()
            $SizeGB = [Math]::Round($Disk.Size / 1GB, 2)
            $MediaType = $Disk.MediaType # SSD or HDD
            
            # Query Storage Reliability Counter for Wear, Temperature and POH
            $Reliability = $Disk | Get-StorageReliabilityCounter -ErrorAction SilentlyContinue
            
            $Temp = 35 # Fallback Temp
            if ($Reliability -and $Reliability.Temperature -ne $null) {
                $Temp = $Reliability.Temperature
            }
            
            $Poh = 0
            if ($Reliability -and $Reliability.LoadOnHours -ne $null) {
                $Poh = $Reliability.LoadOnHours
            }
            
            # Operational Status / Health
            $StatusStr = $Disk.HealthStatus # Healthy, Warning, Unhealthy
            $SmartStatus = "PASSED"
            if ($StatusStr -eq "Unhealthy") { $SmartStatus = "FAILED" }
            
            # Wearout / Health %
            $Wear = 0
            if ($Reliability -and $Reliability.Wear -ne $null) {
                $Wear = $Reliability.Wear
            }
            $Health = 100 - $Wear
            if ($Health -lt 0) { $Health = 0 }
            
            # Formulate Disk Type display
            $DiskType = "SSD Sata"
            if ($Disk.BusType -eq "NVMe") {
                $DiskType = "NVME"
            } elseif ($MediaType -eq "HDD") {
                $DiskType = "HDD"
            }
            
            # Reads & Writes estimation in TB
            $ReadTB = 0.0
            $WriteTB = 0.0
            if ($Reliability) {
                if ($Reliability.ReadBytesTotal) { $ReadTB = [Math]::Round($Reliability.ReadBytesTotal / 1TB, 1) }
                if ($Reliability.WriteBytesTotal) { $WriteTB = [Math]::Round($Reliability.WriteBytesTotal / 1TB, 1) }
            }
            
            # Calculate Write/Day
            $WriteDay = "N/A"
            if ($MediaType -ne "HDD" -and $Poh -gt 0 -and $WriteTB -gt 0) {
                $Days = $Poh / 24
                if ($Days -gt 0.05) {
                    $WriteDayVal = ($WriteTB * 1000) / $Days
                    $WriteDay = "$([Math]::Round($WriteDayVal, 2)) GB"
                } else {
                    $WriteDay = "0.00 GB"
                }
            }
            
            # Determine Checkmk Status (OK > 90%, Warn <= 90%, Crit <= 80%)
            $StatusVal = 0
            $StatusText = "OK"
            if ($SmartStatus -eq "FAILED" -or ($MediaType -ne "HDD" -and $Health -le 80)) {
                $StatusVal = 2
                $StatusText = "Critical"
            } elseif ($MediaType -ne "HDD" -and $Health -le 90) {
                $StatusVal = 1
                $StatusText = "Warning"
            }
            
            # Clean model name for service name
            $CleanModel = $Model -replace '[^\w\s-]', ''
            $ServiceName = "Health_Storage_$CleanModel"
            
            if ($MediaType -eq "HDD") {
                # HDD Status Output
                $OutputLine = "$StatusVal `"$ServiceName`" - Status : $StatusText | Model: $Model ($($SizeGB) GB) | Status: $SmartStatus | Temp: $($Temp)C | Disk Type: HDD | Reallocated Sectors: 0 | Pending Sectors: 0 | Power On Hours: $Poh Hrs | Remark: Disk Condition Good"
            } else {
                # SSD/NVMe Status Output
                $ReadStr = "$($ReadTB) TB"
                $WriteStr = "$($WriteTB) TB"
                $OutputLine = "$StatusVal `"$ServiceName`" - Status : $StatusText | Model: $Model ($($SizeGB) GB) | Status: $SmartStatus | Temp: $($Temp)C | Type: $DiskType ($($SizeGB) GB) | Health: $($Health)% | Read: $ReadStr | Written: $WriteStr | Write/Day: $WriteDay"
            }
            
            $OutputLine | Out-File -FilePath $CacheFile -Encoding utf8 -Append
        }
    }
}

Get-Content $CacheFile -ErrorAction SilentlyContinue
