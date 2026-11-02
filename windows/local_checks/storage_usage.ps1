# =====================================================================
# Local Check Checkmk: Active Storage Capacity Monitor (Windows)
# Hasil dihitung ulang setiap $CacheMinutes menit (0 = selalu hitung ulang).
# =====================================================================

# ---------- Pengaturan ----------
$CacheMinutes = 10    # 0 = tanpa cache (hitung ulang tiap pengambilan agent)
$WarnPct      = 85    # % terpakai -> WARNING
$CritPct      = 95    # % terpakai -> CRITICAL
# --------------------------------

$CacheDir = "$env:ProgramData\checkmk\agent\cache"
if (-not (Test-Path $CacheDir)) { New-Item -ItemType Directory -Force $CacheDir | Out-Null }
$CacheFile = Join-Path $CacheDir "cache_storage_usage.txt"

$NeedUpdate = $true
if ($CacheMinutes -gt 0 -and (Test-Path $CacheFile)) {
    $AgeMinutes = ((Get-Date) - (Get-Item $CacheFile).LastWriteTime).TotalMinutes
    if ($AgeMinutes -lt $CacheMinutes) { $NeedUpdate = $false }
}

if ($NeedUpdate) {
    $Lines = @()

    # Volume lokal aktif (DriveType = 3 = disk lokal)
    $Volumes = Get-CimInstance -ClassName Win32_Volume -Filter "DriveType=3 and DriveLetter <> NULL" -ErrorAction SilentlyContinue

    foreach ($Volume in $Volumes) {
        if (-not $Volume.Capacity) { continue }

        $Mount = $Volume.DriveLetter
        $Label = $Volume.Label
        if (-not $Label) { $Label = "Local Disk" }

        $Capacity  = $Volume.Capacity
        $FreeSpace = $Volume.FreeSpace
        $Used      = $Capacity - $FreeSpace

        $TotalGB = [Math]::Round($Capacity / 1GB, 2)
        $FreeGB  = [Math]::Round($FreeSpace / 1GB, 2)
        $UsedPct = [int](($Used / $Capacity) * 100)

        # Nama service: "C:" -> "C"
        $CleanMount  = $Mount -replace '[^\w\s-]', ''
        $ServiceName = "Storage_Usage_$CleanMount"

        $Status    = 0
        $StatusTxt = "OK"
        if ($UsedPct -ge $CritPct) {
            $Status = 2
            $StatusTxt = "Critical"
        } elseif ($UsedPct -ge $WarnPct) {
            $Status = 1
            $StatusTxt = "Warning"
        }

        $Lines += "$Status `"$ServiceName`" - Status : $StatusTxt | Partition: $Mount ($Label) | Used: $($UsedPct)% | Free: $($FreeGB) GB | Total: $($TotalGB) GB"
    }

    # Tulis cache hanya jika ada hasil, supaya data lama tidak hilang saat query gagal
    if ($Lines.Count -gt 0) {
        $Lines | Out-File -FilePath $CacheFile -Encoding utf8
    }
}

Get-Content $CacheFile -ErrorAction SilentlyContinue
