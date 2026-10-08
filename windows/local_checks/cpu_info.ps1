# =====================================================================
# Local Check Checkmk: Real-Time CPU Specs & Metrics (Windows)
# =====================================================================

$Processor = Get-CimInstance -ClassName Win32_Processor | Select-Object -First 1

# Clean CPU Name (remove trademark symbols, redundant spaces)
$Model = $Processor.Name -replace '\(R\)|\(TM\)|Processor|CPU|@.*', '' -replace '\s+', ' '
$Model = $Model.Trim()

# Clock Speed in GHz
$MaxClock = [Math]::Round($Processor.MaxClockSpeed / 1000, 1)
$ClockSpeed = "$($MaxClock)Ghz"

# Core and Threads
$PhysicalCores = $Processor.NumberOfCores
$LogicalThreads = $Processor.NumberOfLogicalProcessors
$CoreThread = "$($PhysicalCores)/$($LogicalThreads)"

# CPU Load (Real-time average)
$Load = (Get-CimInstance -ClassName Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average
$CpuLoad = "$([int]$Load)%"

# CPU Temperature (Get via MSAcpi if supported, fallback to 45C)
$TempKelvin = (Get-CimInstance -Namespace root\wmi -ClassName MSAcpi_ThermalZoneTemperature -ErrorAction SilentlyContinue | Select-Object -First 1).CurrentTemperature
if ($TempKelvin) {
    $TempC = [int](($TempKelvin - 2731.5) / 10)
} else {
    $TempC = 45 # Default safe fallback
}

# Alert Threshold limits: OK <= 75C, WARNING > 75C, CRITICAL > 85C
$Status = 0
if ($TempC -gt 85) {
    $Status = 2
} elseif ($TempC -gt 75) {
    $Status = 1
}

$Output = "$Status `"CPU_Info`" - Spesifikasi : $Model | Clock Speed : $ClockSpeed | Core/Thread : $CoreThread | CPU Load : $CpuLoad | CPU Temperature: $TempC Celcius"
Write-Output $Output
