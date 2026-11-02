# =====================================================================
# Local Check Checkmk: Weekly RAM Health & Slot Inventory
# Uji RAM dijalankan oleh script ini sendiri sekali seminggu,
# pada pengambilan agent pertama setelah hari Selasa jam 13:00.
# Tidak perlu Scheduled Task atau file lain. Service: Health_RAM
# =====================================================================

$ErrorActionPreference = 'SilentlyContinue'

# ---------- Pengaturan ----------
$MaxTestMB = 1024    # batas uji (jangan di atas 2000: batas array .NET sekitar 2 GB)
$Percent   = 0.20    # bagian dari RAM bebas yang diuji
# --------------------------------

$CacheDir = "$env:ProgramData\checkmk\agent\cache"
if (-not (Test-Path $CacheDir)) { New-Item -ItemType Directory -Force $CacheDir | Out-Null }
$CacheFile = Join-Path $CacheDir "cache_ram_health.txt"

# Selasa 13:00 terakhir (Selasa = 2)
$Now = Get-Date
$DaysToSubtract = ([int]$Now.DayOfWeek - 2 + 7) % 7
if ($DaysToSubtract -eq 0 -and $Now.Hour -lt 13) { $DaysToSubtract = 7 }
$LastTue13 = (Get-Date -Hour 13 -Minute 0 -Second 0).AddDays(-$DaysToSubtract)

$NeedUpdate = $true
if (Test-Path $CacheFile) {
    $CacheMtime = (Get-Item $CacheFile).LastWriteTime

    # Uji ulang juga jika file script ini lebih baru dari cache (script diperbarui)
    $ScriptNewer = $false
    $ScriptPath = $MyInvocation.MyCommand.Path
    if ($ScriptPath -and (Test-Path $ScriptPath)) {
        if ((Get-Item $ScriptPath).LastWriteTime -gt $CacheMtime) { $ScriptNewer = $true }
    }

    if ($CacheMtime -ge $LastTue13 -and -not $ScriptNewer) { $NeedUpdate = $false }
}

if ($NeedUpdate) {
    # --- 1. Slot RAM fisik ---
    $MemoryArray   = Get-CimInstance -ClassName Win32_PhysicalMemoryArray
    $MemoryDevices = Get-CimInstance -ClassName Win32_PhysicalMemory

    $TotalSlots = 0
    if ($MemoryArray) { $TotalSlots = ($MemoryArray | Measure-Object -Property MemoryDevices -Sum).Sum }
    $UsedSlots = 0
    if ($MemoryDevices) { $UsedSlots = ($MemoryDevices | Measure-Object).Count }
    if ($TotalSlots -lt $UsedSlots) { $TotalSlots = $UsedSlots }
    $EmptySlots = $TotalSlots - $UsedSlots

    $ActiveModules = @()
    foreach ($Device in $MemoryDevices) {
        $ActiveModules += "$([Math]::Round($Device.Capacity / 1GB, 1))GiB"
    }
    if ($ActiveModules.Count -gt 0) { $ActiveStr = $ActiveModules -join "," } else { $ActiveStr = "None" }

    $SlotOutput = "Used Slots: $UsedSlots/$TotalSlots ($EmptySlots Empty) | Active Modules: [$ActiveStr]"

    # --- 2. Uji RAM (alokasi + tulis + baca ulang per halaman 4 KB) ---
    $SampleMB   = 0
    $StatusCode = 0
    $StatusTxt  = "OK"
    $ResultTxt  = "Passed"
    $LogSummary = "Memory allocation and system diagnostics passed."

    try {
        $FreeKB = (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).FreePhysicalMemory
        if (-not $FreeKB) { throw "Tidak dapat membaca Free Physical Memory." }

        $SampleMB = [int][Math]::Min($MaxTestMB, [Math]::Max(128, [Math]::Floor(($FreeKB / 1024) * $Percent)))
        $ByteCount = [long]$SampleMB * 1024 * 1024

        $testArray = New-Object Byte[] $ByteCount
        $mismatch = 0
        for ($i = 0; $i -lt $testArray.Length; $i += 4096) { $testArray[$i] = 0xAA }
        for ($i = 0; $i -lt $testArray.Length; $i += 4096) { if ($testArray[$i] -ne 0xAA) { $mismatch++ } }
        $testArray = $null
        [System.GC]::Collect()

        $HwErrors = Get-CimInstance -ClassName Win32_MemoryDevice |
            Where-Object { $_.ErrorCorrecting -eq $true -and $_.ErrorDescription -ne $null }

        if ($mismatch -gt 0) {
            $StatusCode = 2; $StatusTxt = "Critical"; $ResultTxt = "Failed"
            $LogSummary = "Memory test failed: $mismatch data mismatch."
        } elseif ($HwErrors) {
            $StatusCode = 2; $StatusTxt = "Critical"; $ResultTxt = "Failed"
            $LogSummary = "Memory test failed: hardware error reported by Windows."
        }
    } catch {
        $StatusCode = 2; $StatusTxt = "Critical"; $ResultTxt = "Failed"
        $Reason = ("$_" -replace '\s+', ' ').Trim()
        if ($Reason.Length -gt 200) { $Reason = $Reason.Substring(0, 200) + '...' }
        $LogSummary = "Memory test failed during allocation or hardware diagnostics. Reason: $Reason"
    }

    $TestTime = Get-Date -Format "yyyy-MM-dd HH:mm"
    $Output = "$StatusCode `"Health_RAM`" - Status : $StatusTxt | Result: $ResultTxt | Tested Size: ${SampleMB}M | Last Test: $TestTime | $SlotOutput | Log: $LogSummary"

    $Output | Out-File -FilePath $CacheFile -Encoding utf8 -Force
}

Get-Content $CacheFile -ErrorAction SilentlyContinue
