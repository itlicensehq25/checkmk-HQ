# =====================================================================
# Local Check Checkmk: Real-Time Network Info & Throughput (Windows)
# =====================================================================

# Get Active Up Interfaces
$ActiveAdapters = Get-NetAdapter | Where-Object { $_.Status -eq "Up" }

if (-not $ActiveAdapters) {
    "0 `"Info_Network_NoActive`" - OK - No active network interfaces detected."
    Exit
}

foreach ($Adapter in $ActiveAdapters) {
    $IfaceName = $Adapter.Name
    $CleanIfaceName = $IfaceName -replace '[^\w\s-]', ''
    
    # Get IP Address
    $IP = (Get-NetIPAddress -InterfaceAlias $IfaceName -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -First 1).IPAddress
    if (-not $IP) { $IP = "No IP" }
    
    # Sample Phase 1
    $Stats1 = $Adapter | Get-NetAdapterStatistics -ErrorAction SilentlyContinue
    if (-not $Stats1) { continue }
    $Rx1 = $Stats1.ReceivedBytes
    $Tx1 = $Stats1.SentBytes
    
    # Sleep 1 second to calculate rates
    Start-Sleep -Seconds 1
    
    # Sample Phase 2
    $Stats2 = $Adapter | Get-NetAdapterStatistics -ErrorAction SilentlyContinue
    if (-not $Stats2) { continue }
    $Rx2 = $Stats2.ReceivedBytes
    $Tx2 = $Stats2.SentBytes
    
    # Calculate Rates
    $RxRate = $Rx2 - $Rx1
    $TxRate = $Tx2 - $Tx1
    if ($RxRate -lt 0) { $RxRate = 0 }
    if ($TxRate -lt 0) { $TxRate = 0 }
    
    # Convert Totals (Bytes to HR format)
    $FormatTotal = {
        param([uint64]$b)
        if ($b -ge 1073741824) { [String]::Format("{0:F2} GB", $b/1073741824) }
        elseif ($b -ge 1048576) { [String]::Format("{0:F2} MB", $b/1048576) }
        else { [String]::Format("{0:F2} KB", $b/1024) }
    }
    
    $TotalRxHR = &$FormatTotal $Rx2
    $TotalTxHR = &$FormatTotal $Tx2
    
    # Convert Rates to HR format
    $FormatRate = {
        param([uint64]$b)
        if ($b -ge 1048576) { [String]::Format("{0:F2} MB/s", $b/1048576) }
        elseif ($b -ge 1024) { [String]::Format("{0:F2} KB/s", $b/1024) }
        else { "$($b) B/s" }
    }
    
    $RxRateHR = &$FormatRate $RxRate
    $TxRateHR = &$FormatRate $TxRate
    
    # Checkmk Service Output
    $ServiceName = "Info_Network_$CleanIfaceName"
    Write-Output "0 `"$ServiceName`" in=$($Rx2)c|out=$($Tx2)c OK - IP Address: $IP | Total Download: $TotalRxHR | Total Upload: $TotalTxHR | RX Rate : $RxRateHR | TX Rate : $TxRateHR"
}
