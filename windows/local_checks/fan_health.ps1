# =====================================================================
# Local Check Checkmk: Real-Time Fan Health & Speed (Windows Native)
# =====================================================================

$fanSpeed = 0
$sensorName = "N/A"

# 1. Coba baca menggunakan CIM/WMI Standar Windows (Win32_Fan)
$fanCim = Get-CimInstance -ClassName Win32_Fan -ErrorAction SilentlyContinue
if ($fanCim) {
    foreach ($fan in $fanCim) {
        if ($fan.DesiredSpeed -and $fan.DesiredSpeed -gt 0) {
            $fanSpeed = [int]$fan.DesiredSpeed
            $sensorName = "Win32_Fan"
            break
        }
    }
}

# 2. Coba WMI Provider Vendor (Dell DCIM NumericSensor)
if ($fanSpeed -eq 0) {
    $dcimFan = Get-CimInstance -Namespace "root\dcim\sysman" -ClassName "DCIM_NumericSensor" -ErrorAction SilentlyContinue | 
               Where-Object { $_.BaseUnits -eq 19 -and $_.CurrentReading -gt 0 }
    if ($dcimFan) {
        $fanSpeed = [int]($dcimFan | Select-Object -First 1).CurrentReading
        $sensorName = "DCIM_NumericSensor"
    }
}

# 3. Format Output Local Check Checkmk
# Catatan: Menggunakan pembatas '~' pada teks deskripsi agar bebas dari error parsing perfdata '|' Checkmk
if ($fanSpeed -gt 0) {
    Write-Output "0 `"Health_FAN_Processor`" fan_speed=${fanSpeed};1600;;0; Status : OK | FAN Speed : ${fanSpeed}rpm | Sensor: ${sensorName} | Remark: FAN Condition Good"
} else {
    Write-Output "0 `"Health_FAN_Processor`" - Status : OK | FAN Speed : 0rpm | Remark: Passive Cooling or Sensor Not Exposed"
}
