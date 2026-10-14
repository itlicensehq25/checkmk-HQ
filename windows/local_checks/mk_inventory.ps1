# Copyright (C) 2025 Checkmk GmbH - License: GNU General Public License v2
# This file is part of Checkmk (https://checkmk.com). It is subject to the terms and
# conditions defined in the file COPYING, which is part of this source code package.

$CMK_VERSION = "2.5.0p15"
$HKLM = "HKLM:\"

function GetEnvVar {
    param([string]$name)
    return [System.Environment]::GetEnvironmentVariable($name)
}

function Initialize {
    # These three lines are default in case not set in the agent bakery
    $script:delay = 14400
    $script:exePaths = @()
    $script:regPaths = @("Software\Microsoft\Windows\CurrentVersion\Uninstall",
        "Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall")

    $script:stateDir = GetEnvVar("MK_STATEDIR")
    $script:confDir = GetEnvVar("MK_CONFDIR")
    $script:remoteHost = GetEnvVar("REMOTE_HOST")

    # Set values from the bakery configuration file
    if ($script:confDir) {
        $confJson = Join-Path $script:confDir "mk_inventory_cfg.json"

        if (Test-Path $confJson) {
            $jsonContent = Get-Content -Path $confJson -Raw
            $config = ConvertFrom-Json -InputObject $jsonContent
            if ($config) {
                $script:delay = $config.delay
                $script:exePaths = $config.exePaths
                $script:regPaths = $config.regPaths
            }
        }
    }

    # Default values if environment variables are missing
    if (-not $script:remoteHost) {
        $script:remoteHost = "local"
    }
    # Fallback if an (old) agent does not provide the MK_STATEDIR
    if ($script:confDir -and -not $script:stateDir) {
        $script:stateDir = $script:confDir
    }
}

function CreateTimestamp {
    # Create timestamp only in case env variables are properly resolved
    # Run script without a timestamp otherwise
    if ($script:stateDir) {
        # Define timestamp file
        $timestamp = "$script:stateDir\mk_inventory.$($script:remoteHost -replace ':', '_')"

        # Check if timestamp file exists and its last modified time
        if (Test-Path $timestamp) {
            $fileDate = (Get-Item $timestamp).LastWriteTime
            # Exit if timestamp is too young
            if ($fileDate.AddSeconds($script:delay) -ge (Get-Date)) {
                return "Exiting the script because timestamp is too young."
            }
        }

        # Create new timestamp file (requires admin rights)
        try {
            New-Item -Path $timestamp -ItemType File -Force -ErrorAction Stop
        }
        catch {
            Write-Output "Failed to create timestamp: $_"
        }
    }
}

function GetTimeUntil {
    # Get the current Unix timestamp
    $epoch = [int](([datetime]::UtcNow - [datetime]'1970-01-01').TotalSeconds)
    # Add delay and 5 minutes (300 seconds)
    return $epoch + $script:delay + 300
}

function StartSection {
    param (
        [string]$name,
        [string]$sep,
        [string]$timeUntil
    )
    Write-Output "<<<${name}:sep(${sep}):persist(${timeUntil})>>>"
}

function GetWmiObject {
    param (
        [string]$strClass,
        [string[]]$arrVars
    )
    $entries = Get-CimInstance -ClassName $strClass -Namespace "root\cimv2"
    foreach ($entry in $entries) {
        $sortedProperties = $entry.PSObject.Properties |
        Where-Object { $_.Name -in $arrVars } |
        Sort-Object Name

        foreach ($property in  $sortedProperties) {
            if ($arrVars -contains $property.Name) {
                $value = $property.Value

                # Convert Date to the format expected by the parser
                if ($value -is [datetime]) {
                    $value = [System.Management.ManagementDateTimeConverter]::ToDmtfDateTime($value)
                }

                if ($value -is [array]) {
                    Write-Output("{0}: {1}" -f $property.Name, ($value -join " "))
                }
                else {
                    Write-Output("{0}: {1}" -f $property.Name, $value)
                }
            }
        }
    }
}

function GetWmiObject2 {
    param (
        [string]$ClassName,
        [string[]]$arrVars
    )
    $entries = Get-CimInstance -ClassName $ClassName -Namespace "root\cimv2"
    foreach ($entry in $entries) {
        $values = @()
        foreach ($label in $arrVars) {
            $property = $entry.PSObject.Properties[$label]
            $value = if ($property) { $property.Value } else { "" }

            # Convert Date to the format expected by the parser
            if ($value -is [datetime]) {
                $value = [System.Management.ManagementDateTimeConverter]::ToDmtfDateTime($value)
            }

            # Append Update Build Revision (UBR) to the version property
            if ($label -eq "version") {
                $ubr = (Get-ItemProperty -Path "${HKLM}SOFTWARE\Microsoft\Windows NT\CurrentVersion").UBR
                if ($ubr) {
                    $value = "$value.$ubr"
                }
            }

            $values += $value
        }
        Write-Output ($values -join "|")
    }
}

function GetNetworkAdapter {
    param (
        [string[]]$arrVars
    )
    $adapters = Get-CimInstance -ClassName "Win32_NetworkAdapter" -Namespace "root\cimv2"
    $adapterConfigs = Get-CimInstance -ClassName "Win32_NetworkAdapterConfiguration" -Namespace "root\cimv2"
    foreach ($adapter in $adapters) {
        # Only handle Adapters with a MAC address and exclude AsyncMac
        if ($adapter.ServiceName -ne "AsyncMac" -and -not [string]::IsNullOrEmpty($adapter.MACAddress)) {
            $sortedProperties = $adapter.PSObject.Properties |
            Where-Object { $_.Name -in $arrVars } |
            Sort-Object Name
            foreach ($property in $sortedProperties) {
                if ($arrVars -contains $property.Name) {
                    if ($property.Value -is [array]) {
                        Write-Output ("{0}: {1}" -f $property.Name, ($property.Value -join " "))
                    }
                    else {
                        Write-Output ("{0}: {1}" -f $property.Name, $property.Value)
                    }
                }
            }
            # Find matching network adapter configuration
            $adapterConfig = $adapterConfigs | Where-Object { $_.Description -eq $adapter.Name }
            if ($adapterConfig) {
                if ($adapterConfig.IPAddress) {
                    Write-Output ("Address: {0}" -f ($adapterConfig.IPAddress -join " "))
                }
                if ($adapterConfig.IPSubnet) {
                    Write-Output ("Subnet: {0}" -f ($adapterConfig.IPSubnet -join " "))
                }
                if ($adapterConfig.DefaultIPGateway) {
                    Write-Output ("DefaultGateway: {0}" -f ($adapterConfig.DefaultIPGateway -join " "))
                }
            }
        }
    }
}

function GetRouteTable {
    $adapters = Get-CimInstance -ClassName "Win32_NetworkAdapter" -Namespace "root\cimv2"
    $routes = Get-CimInstance -ClassName "Win32_IP4RouteTable" -Namespace "root\cimv2"

    $indexNames = @{}
    foreach ($adapter in $adapters) {
        $indexNames[[int]$adapter.InterfaceIndex] = $adapter.Name
    }

    $routeTypes = @{
        1 = "other"
        2 = "invalid"
        3 = "direct"
        4 = "indirect"
    }

    foreach ($route in $routes) {
        $rtType = [string]$routeTypes[[int]$route.Type]
        $rtGateway = $route.NextHop
        $rtTarget = $route.Destination
        $rtMask = $route.Mask
        $rtDevice = [string]$indexNames[[int]$route.InterfaceIndex]
        if ($rtDevice) {
            Write-Output ("{0}|{1}|{2}|{3}|{4}" -f $rtType, $rtTarget, $rtMask, $rtGateway, $rtDevice)
        }
    }
}

function GetSoftwareFromInstaller {
    param (
        [string[]]$fields,
        $installer = $null # For dependency injection in tests
    )
    $WI_SID_EVERYONE = "s-1-1-0"
    $WI_ALL_CONTEXTS = 7
    # Create Windows Installer COM object
    if (-not $installer) {
        $installer = New-Object -ComObject WindowsInstaller.Installer
    }
    
    # Try getting products using ProductsEx
    try {
        $products = $installer.ProductsEx("", $WI_SID_EVERYONE, $WI_ALL_CONTEXTS)
        $productsEx = $true
    }
    catch {
        $productsEx = $false
        try {
            $products = $installer.Products()
        }
        catch {
            Write-Output "Cannot list installed software: $_"
            return
        }
    }
    # Iterate over installed software
    foreach ($item in $products) {
        try {
            if ($productsEx) {
                # Using ProductsEx method
                $product = $item
                $productCode = $product.ProductCode
                $values = @()
                foreach ($field in $fields) {
                    $values += $product.InstallProperty($field)
                }
                Write-Output ($values -join "$([char]31)")
            }
            else {
                # Using Products method
                $productCode = $item
                $values = @()
                foreach ($field in $fields) {
                    $values += $installer.ProductInfo($productCode, $field)
                }
                Write-Output ($values -join "$([char]31)")
            }
        }
        catch {
            # Ignore errors and continue
            continue
        }
    }
}

function GetUpdates {
    Write-Output "Node,Description,HotFixID,InstalledOn"
    $computerName = (Get-CimInstance Win32_ComputerSystem).Name
    Get-HotFix | ForEach-Object {
        $installedOn = $_.InstalledOn
        if ($installedOn -is [datetime]) {
            # Remove leading zeros using 'M/d/yyyy'
            $installedOn = $installedOn.ToString("M/d/yyyy")
        }
        Write-Output "$computerName,$($_.Description),$($_.HotFixID),$($installedOn)"
    }
}

function EscapeRegistryPath {
    param (
        [string]$Path
    )
    return $Path -replace '([]`*\?\[""])', '`$1'
}

function GetSoftwareFromRegistry {
    $regVars = @("DisplayName", "Publisher", "InstallLocation", "PSChildName", "DisplayVersion", "EstimatedSize", "InstallDate", "Language")

    foreach ($path in $regPaths) {
        $machineHivePath = "$HKLM$path"
        if (Test-Path $machineHivePath) {
            $subkeys = Get-ChildItem -Path $machineHivePath

            foreach ($subkey in $subkeys) {
                $values = @()
                $booleanContent = $false

                foreach ($var in $regVars) {
                    $escapedRegistryPath = EscapeRegistryPath $subkey.PSPath
                    if ($var -eq "PSChildName") {
                        $value = $subkey.PSChildName
                    }
                    elseif ($var -eq "Language") {
                        $value = (Get-ItemProperty -Path $escapedRegistryPath -Name $var -ErrorAction SilentlyContinue).$var
                        if ($null -ne $value) {
                            $value = $value.ToString()
                        }
                    }
                    else {
                        $value = (Get-ItemProperty -Path $escapedRegistryPath -Name $var -ErrorAction SilentlyContinue).$var
                    }

                    if ($null -ne $value -and $value -is [string]) {
                        $values += $value.Replace(
                            # We have seen output that contains ASCII control characters.
                            # If we don't replace them, they will break the parsing later on.
                            # Replacing NUL with the empty string does not affect the output shown in the HW/SW inventory, since NUL is anyway rendered as the empty string.
                            "$([char]0)", ""
                        )
                        if ($var -ne "PSChildName") {
                            $booleanContent = $true
                        }
                    }
                    else {
                        $values += ""  # Ensure empty placeholders are present
                    }
                }

                if ($booleanContent) {
                    Write-Output ($values -join "$([char]0)")
                }
            }
        }
    }
}

function RecurseFolderForExecs {
    param (
        [string]$folderPath
    )

    # Get all files in the current folder
    Get-ChildItem -Path $folderPath -File | ForEach-Object {
        # Check if the file has an extension and if it's ".exe"
        if ($_.Extension -eq ".exe") {
            # Get file version (if available)
            $fileVersion = (Get-Item $_.FullName).VersionInfo.FileVersionRaw

            # Output file details
            Write-Output ("$($_.FullName)|$(Get-Date $_.LastWriteTime -Format 'M/d/yyyy HH:mm:ss')|$($_.Length)||$fileVersion|")
        }
    }

    # Recursively process subfolders
    Get-ChildItem -Path $folderPath -Directory | ForEach-Object {
        RecurseFolderForExecs $_.FullName
    }
}

function GetIpParametersTable {
    $addresses = Get-NetIPAddress -ErrorAction SilentlyContinue

    $items = foreach ($addr in $addresses) {
        "{0} {1} {2}" -f $addr.IPAddress, $addr.PrefixOrigin, $addr.SuffixOrigin
    }

    if ($items) {
        "Parameters: {0}" -f ($items -join ",")
    } else {
        "Parameters:"
    }
}

function GetSoftwareFromFilesystem {
    foreach ($path in $exePaths) {
        if (Test-Path -Path $path -PathType Container) {
            RecurseFolderForExecs $path
        }
    }
}

Initialize
$result = CreateTimestamp
if ($result -eq "Exiting the script because timestamp is too young.") {
    return
}
else {
    # other cases are irrelevant: problems with I/O, lack of STATE_DIR, etc.
    # some additional diags will be added with separate commit
}
$timeUntil = GetTimeUntil

# Processor
StartSection "win_cpuinfo" 58 $timeUntil
GetWmiObject "Win32_Processor" @("Name", "Manufacturer", "Caption", "DeviceID", "MaxClockSpeed", "AddressWidth", "L2CacheSize", "L3CacheSize", "Architecture", "NumberOfCores", "NumberOfLogicalProcessors", "CurrentVoltage", "Status")

# OS Version
StartSection "win_os" 124 $timeUntil
GetWmiObject2 "Win32_OperatingSystem" @("csname", "caption", "version", "OSArchitecture", "servicepackmajorversion", "ServicePackMinorVersion", "InstallDate")

# Memory
# StartSection "win_memory" 58 $timeUntil
# GetWmiObject "Win32_PhysicalMemory" @("BankLabel","DeviceLocator","Capacity","Manufacturer","PartNumber","SerialNumber","Speed")

# BIOS
StartSection "win_bios" 58 $timeUntil
GetWmiObject "Win32_bios" @("Manufacturer", "Name", "SerialNumber", "InstallDate", "BIOSVersion", "ListOfLanguages", "PrimaryBIOS", "ReleaseDate", "SMBIOSBIOSVersion", "SMBIOSMajorVersion", "SMBIOSMinorVersion")

# System
StartSection "win_system" 58 $timeUntil
GetWmiObject "Win32_SystemEnclosure" @("Manufacturer", "Name", "Model", "HotSwappable", "InstallDate", "PartNumber", "SerialNumber")

# ComputerSystem
StartSection "win_computersystem" 58 $timeUntil
GetWmiObject "Win32_ComputerSystem" @("Manufacturer", "Name", "Model", "InstallDate")

# ComputerSystemProduct
StartSection "win_computersystemproduct" 58 $timeUntil
GetWmiObject "Win32_ComputerSystemProduct" @("UUID")

# Hard-Disk
StartSection "win_disks" 58 $timeUntil
GetWmiObject "Win32_diskDrive" @("Manufacturer", "InterfaceType", "Model", "Name", "SerialNumber", "Size", "MediaType", "Signature")

# Graphics Adapter
StartSection "win_video" 58 $timeUntil
GetWmiObject "Win32_VideoController" @("Name", "Description", "Caption", "AdapterCompatibility", "VideoModeDescription", "VideoProcessor", "DriverVersion", "DriverDate", "MaxMemorySupported", "AdapterRAM")

# Network Adapter
StartSection "win_networkadapter" 58 $timeUntil
GetNetworkAdapter @("Name", "ServiceName", "MACAddress", "AdapterType", "DeviceID", "NetworkAddresses", "Speed")
# Network Adapter Parameters IP address, prefix, suffix, etc.
GetIpParametersTable

# Route Table
StartSection "win_ip_r" 124 $timeUntil
GetRouteTable

# Installed Software
StartSection "win_wmi_software" 31 $timeUntil
GetSoftwareFromInstaller @("ProductName", "Publisher", "VersionString", "InstallDate", "Language")

# Windows Updates
StartSection "win_wmi_updates" 44 $timeUntil
GetUpdates

# Search Registry
StartSection "win_reg_uninstall" 0 $timeUntil
GetSoftwareFromRegistry

# Search exes
StartSection "win_exefiles" 124 $timeUntil
GetSoftwareFromFilesystem

# SIG # Begin signature block
# MII5ygYJKoZIhvcNAQcCoII5uzCCObcCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCC1o8K9lk+/KB8O
# y0vTC7Mf7jUeOBx3tgzkfoiNYZnfqKCCIe4wggXMMIIDtKADAgECAhBUmNLR1FsZ
# lUgTecgRwIeZMA0GCSqGSIb3DQEBDAUAMHcxCzAJBgNVBAYTAlVTMR4wHAYDVQQK
# ExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xSDBGBgNVBAMTP01pY3Jvc29mdCBJZGVu
# dGl0eSBWZXJpZmljYXRpb24gUm9vdCBDZXJ0aWZpY2F0ZSBBdXRob3JpdHkgMjAy
# MDAeFw0yMDA0MTYxODM2MTZaFw00NTA0MTYxODQ0NDBaMHcxCzAJBgNVBAYTAlVT
# MR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xSDBGBgNVBAMTP01pY3Jv
# c29mdCBJZGVudGl0eSBWZXJpZmljYXRpb24gUm9vdCBDZXJ0aWZpY2F0ZSBBdXRo
# b3JpdHkgMjAyMDCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBALORKgeD
# Bmf9np3gx8C3pOZCBH8Ppttf+9Va10Wg+3cL8IDzpm1aTXlT2KCGhFdFIMeiVPvH
# or+Kx24186IVxC9O40qFlkkN/76Z2BT2vCcH7kKbK/ULkgbk/WkTZaiRcvKYhOuD
# PQ7k13ESSCHLDe32R0m3m/nJxxe2hE//uKya13NnSYXjhr03QNAlhtTetcJtYmrV
# qXi8LW9J+eVsFBT9FMfTZRY33stuvF4pjf1imxUs1gXmuYkyM6Nix9fWUmcIxC70
# ViueC4fM7Ke0pqrrBc0ZV6U6CwQnHJFnni1iLS8evtrAIMsEGcoz+4m+mOJyoHI1
# vnnhnINv5G0Xb5DzPQCGdTiO0OBJmrvb0/gwytVXiGhNctO/bX9x2P29Da6SZEi3
# W295JrXNm5UhhNHvDzI9e1eM80UHTHzgXhgONXaLbZ7LNnSrBfjgc10yVpRnlyUK
# xjU9lJfnwUSLgP3B+PR0GeUw9gb7IVc+BhyLaxWGJ0l7gpPKWeh1R+g/OPTHU3mg
# trTiXFHvvV84wRPmeAyVWi7FQFkozA8kwOy6CXcjmTimthzax7ogttc32H83rwjj
# O3HbbnMbfZlysOSGM1l0tRYAe1BtxoYT2v3EOYI9JACaYNq6lMAFUSw0rFCZE4e7
# swWAsk0wAly4JoNdtGNz764jlU9gKL431VulAgMBAAGjVDBSMA4GA1UdDwEB/wQE
# AwIBhjAPBgNVHRMBAf8EBTADAQH/MB0GA1UdDgQWBBTIftJqhSobyhmYBAcnz1AQ
# T2ioojAQBgkrBgEEAYI3FQEEAwIBADANBgkqhkiG9w0BAQwFAAOCAgEAr2rd5hnn
# LZRDGU7L6VCVZKUDkQKL4jaAOxWiUsIWGbZqWl10QzD0m/9gdAmxIR6QFm3FJI9c
# Zohj9E/MffISTEAQiwGf2qnIrvKVG8+dBetJPnSgaFvlVixlHIJ+U9pW2UYXeZJF
# xBA2CFIpF8svpvJ+1Gkkih6PsHMNzBxKq7Kq7aeRYwFkIqgyuH4yKLNncy2RtNwx
# AQv3Rwqm8ddK7VZgxCwIo3tAsLx0J1KH1r6I3TeKiW5niB31yV2g/rarOoDXGpc8
# FzYiQR6sTdWD5jw4vU8w6VSp07YEwzJ2YbuwGMUrGLPAgNW3lbBeUU0i/OxYqujY
# lLSlLu2S3ucYfCFX3VVj979tzR/SpncocMfiWzpbCNJbTsgAlrPhgzavhgplXHT2
# 6ux6anSg8Evu75SjrFDyh+3XOjCDyft9V77l4/hByuVkrrOj7FjshZrM77nq81YY
# uVxzmq/FdxeDWds3GhhyVKVB0rYjdaNDmuV3fJZ5t0GNv+zcgKCf0Xd1WF81E+Al
# GmcLfc4l+gcK5GEh2NQc5QfGNpn0ltDGFf5Ozdeui53bFv0ExpK91IjmqaOqu/dk
# ODtfzAzQNb50GQOmxapMomE2gj4d8yu8l13bS3g7LfU772Aj6PXsCyM2la+YZr9T
# 03u4aUoqlmZpxJTG9F9urJh4iIAGXKKy7aIwggakMIIEjKADAgECAhMzAAdtUPzn
# 8fi/cXV9AAAAB21QMA0GCSqGSIb3DQEBDAUAMFoxCzAJBgNVBAYTAlVTMR4wHAYD
# VQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKzApBgNVBAMTIk1pY3Jvc29mdCBJ
# RCBWZXJpZmllZCBDUyBBT0MgQ0EgMDQwHhcNMjYwOTMwMDMzMTQ2WhcNMjYxMDAz
# MDMzMTQ2WjBmMQswCQYDVQQGEwJERTEQMA4GA1UECBMHQmF2YXJpYTEXMBUGA1UE
# Bx4OAE0A/ABuAGMAaABlAG4xFTATBgNVBAoTDENoZWNrbWsgR21iSDEVMBMGA1UE
# AxMMQ2hlY2ttayBHbWJIMIIBojANBgkqhkiG9w0BAQEFAAOCAY8AMIIBigKCAYEA
# riwDbPIzo54tCiTyLkjK9+IIsWpiY2LIJN6m/ulcnC81wnPL68DL1Dl99Dg+p2FQ
# bEfK8iM+Y7UPN1mQYkI7yg2v8I2HbUUsi6SbMzNU7Wei86RAAHP9wRHcjzaMSSAm
# SNmTIb28Yvn8sXyxYm68r8SoWHnivTO48BdgXcm03KIKn9Y4nDhV1QzAGxyUWnm+
# v10mV8uARVI2cZb8BtCWhdm/Ogl8CpGDNmD/bnCa0e6rTcXtuRrUgQ7JBjWQHP/w
# zc5JOJ/gwrUxdPSEbh3EogPBaUGR/A8vLcwvl//MrgEVJEjSkRdVvPYvO6OiqP+F
# uHai+liAu8iWLvvwwDplm1E1HT5YrjFjgRK4bfbF/OmCDYqSfY846MGhThLoR0Lz
# Aw7qtc997QdG8lpwlszCucaVTEXuSdJBKMmIcPm0HkxvWlvNwPYW0ZXFWIa4O6kd
# cnJesPflZ8JX0OAmSNPBuP2XdDOXueKWKugfzNSGF910PoG1erE7NvzeASRkaQL5
# AgMBAAGjggHVMIIB0TAMBgNVHRMBAf8EAjAAMA4GA1UdDwEB/wQEAwIHgDA8BgNV
# HSUENTAzBgorBgEEAYI3YQEABggrBgEFBQcDAwYbKwYBBAGCN2GY8vE3gaHaijyD
# tuvXSYPNo7wWMB0GA1UdDgQWBBT/JS54z+QZ6Kht80faVAEvqJP73TAfBgNVHSME
# GDAWgBRrJUHe+2t8/RiACi1/j3ZdqnM9uDBnBgNVHR8EYDBeMFygWqBYhlZodHRw
# Oi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NybC9NaWNyb3NvZnQlMjBJRCUy
# MFZlcmlmaWVkJTIwQ1MlMjBBT0MlMjBDQSUyMDA0LmNybDB0BggrBgEFBQcBAQRo
# MGYwZAYIKwYBBQUHMAKGWGh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMv
# Y2VydHMvTWljcm9zb2Z0JTIwSUQlMjBWZXJpZmllZCUyMENTJTIwQU9DJTIwQ0El
# MjAwNC5jcnQwVAYDVR0gBE0wSzBJBgRVHSAAMEEwPwYIKwYBBQUHAgEWM2h0dHA6
# Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvRG9jcy9SZXBvc2l0b3J5Lmh0bTAN
# BgkqhkiG9w0BAQwFAAOCAgEAIsprZKdpC9Ktlos+JH/SJyvGjRXfOQgYFA9lOH2f
# RMMid423tnG4XJkEKHKHNzvjgXlQQi9jpf1SYIyjd5KK2J2VL6xEyg6zrKom8RbN
# TQDAPWuJLnSNyww3ZsBYLvHGtQDtuVZ2xD4jYWGtShCSjnID3imu5J5R4eAijKV0
# ewsOedSSjlSNmQMU/SYG6jMJyTkecKqdyMnzIQ1eVzGkDWc+ysL/271XCoQCLNGz
# ZjOyVWDR0Ea8HdX1d/0EItd23//wLWXEz5lzxjH/tYGF/PNqm2kMVHQlvqPin14c
# Y1ldW9Hw/sg3esnxOeGhjl3jLkOgefwwI57U3GZt+j/KSNs5H9t50gTRElt+zblR
# LJPqO4XBSRW9IP4pNzg5QdR6Y9MdCKiTOBoFyn+huBXTM9QBgusvCPJ6SLZ08Yos
# jmPKYevA4I9tNdbicXrt5G2tmnqg39MZOnyKzfvaXN7Z8ZqbLMnYp7qT5KVZkhzp
# XxefIvXbjejB5q35pvotPvNngpD6vTc2d7RSXa8ft5T4RIcbWU/9NHUmlO15npe8
# ItIv5LUGteQmSqbnqWS6z8shZodUDPigP7e7HC0M7mQcc/vYhEgMBik4Uk4mPzqC
# k04hrlQP2/3MSlj11qV/pm14Q7Oo79j07cUS0S4O2M8GSHdR9JR7sf19OleDbOkr
# 7XAwggakMIIEjKADAgECAhMzAAdtUPzn8fi/cXV9AAAAB21QMA0GCSqGSIb3DQEB
# DAUAMFoxCzAJBgNVBAYTAlVTMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRp
# b24xKzApBgNVBAMTIk1pY3Jvc29mdCBJRCBWZXJpZmllZCBDUyBBT0MgQ0EgMDQw
# HhcNMjYwOTMwMDMzMTQ2WhcNMjYxMDAzMDMzMTQ2WjBmMQswCQYDVQQGEwJERTEQ
# MA4GA1UECBMHQmF2YXJpYTEXMBUGA1UEBx4OAE0A/ABuAGMAaABlAG4xFTATBgNV
# BAoTDENoZWNrbWsgR21iSDEVMBMGA1UEAxMMQ2hlY2ttayBHbWJIMIIBojANBgkq
# hkiG9w0BAQEFAAOCAY8AMIIBigKCAYEAriwDbPIzo54tCiTyLkjK9+IIsWpiY2LI
# JN6m/ulcnC81wnPL68DL1Dl99Dg+p2FQbEfK8iM+Y7UPN1mQYkI7yg2v8I2HbUUs
# i6SbMzNU7Wei86RAAHP9wRHcjzaMSSAmSNmTIb28Yvn8sXyxYm68r8SoWHnivTO4
# 8BdgXcm03KIKn9Y4nDhV1QzAGxyUWnm+v10mV8uARVI2cZb8BtCWhdm/Ogl8CpGD
# NmD/bnCa0e6rTcXtuRrUgQ7JBjWQHP/wzc5JOJ/gwrUxdPSEbh3EogPBaUGR/A8v
# Lcwvl//MrgEVJEjSkRdVvPYvO6OiqP+FuHai+liAu8iWLvvwwDplm1E1HT5YrjFj
# gRK4bfbF/OmCDYqSfY846MGhThLoR0LzAw7qtc997QdG8lpwlszCucaVTEXuSdJB
# KMmIcPm0HkxvWlvNwPYW0ZXFWIa4O6kdcnJesPflZ8JX0OAmSNPBuP2XdDOXueKW
# KugfzNSGF910PoG1erE7NvzeASRkaQL5AgMBAAGjggHVMIIB0TAMBgNVHRMBAf8E
# AjAAMA4GA1UdDwEB/wQEAwIHgDA8BgNVHSUENTAzBgorBgEEAYI3YQEABggrBgEF
# BQcDAwYbKwYBBAGCN2GY8vE3gaHaijyDtuvXSYPNo7wWMB0GA1UdDgQWBBT/JS54
# z+QZ6Kht80faVAEvqJP73TAfBgNVHSMEGDAWgBRrJUHe+2t8/RiACi1/j3ZdqnM9
# uDBnBgNVHR8EYDBeMFygWqBYhlZodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtp
# b3BzL2NybC9NaWNyb3NvZnQlMjBJRCUyMFZlcmlmaWVkJTIwQ1MlMjBBT0MlMjBD
# QSUyMDA0LmNybDB0BggrBgEFBQcBAQRoMGYwZAYIKwYBBQUHMAKGWGh0dHA6Ly93
# d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY2VydHMvTWljcm9zb2Z0JTIwSUQlMjBW
# ZXJpZmllZCUyMENTJTIwQU9DJTIwQ0ElMjAwNC5jcnQwVAYDVR0gBE0wSzBJBgRV
# HSAAMEEwPwYIKwYBBQUHAgEWM2h0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lv
# cHMvRG9jcy9SZXBvc2l0b3J5Lmh0bTANBgkqhkiG9w0BAQwFAAOCAgEAIsprZKdp
# C9Ktlos+JH/SJyvGjRXfOQgYFA9lOH2fRMMid423tnG4XJkEKHKHNzvjgXlQQi9j
# pf1SYIyjd5KK2J2VL6xEyg6zrKom8RbNTQDAPWuJLnSNyww3ZsBYLvHGtQDtuVZ2
# xD4jYWGtShCSjnID3imu5J5R4eAijKV0ewsOedSSjlSNmQMU/SYG6jMJyTkecKqd
# yMnzIQ1eVzGkDWc+ysL/271XCoQCLNGzZjOyVWDR0Ea8HdX1d/0EItd23//wLWXE
# z5lzxjH/tYGF/PNqm2kMVHQlvqPin14cY1ldW9Hw/sg3esnxOeGhjl3jLkOgefww
# I57U3GZt+j/KSNs5H9t50gTRElt+zblRLJPqO4XBSRW9IP4pNzg5QdR6Y9MdCKiT
# OBoFyn+huBXTM9QBgusvCPJ6SLZ08YosjmPKYevA4I9tNdbicXrt5G2tmnqg39MZ
# OnyKzfvaXN7Z8ZqbLMnYp7qT5KVZkhzpXxefIvXbjejB5q35pvotPvNngpD6vTc2
# d7RSXa8ft5T4RIcbWU/9NHUmlO15npe8ItIv5LUGteQmSqbnqWS6z8shZodUDPig
# P7e7HC0M7mQcc/vYhEgMBik4Uk4mPzqCk04hrlQP2/3MSlj11qV/pm14Q7Oo79j0
# 7cUS0S4O2M8GSHdR9JR7sf19OleDbOkr7XAwggcoMIIFEKADAgECAhMzAAAAFjGS
# jZICZXuaAAAAAAAWMA0GCSqGSIb3DQEBDAUAMGMxCzAJBgNVBAYTAlVTMR4wHAYD
# VQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xNDAyBgNVBAMTK01pY3Jvc29mdCBJ
# RCBWZXJpZmllZCBDb2RlIFNpZ25pbmcgUENBIDIwMjEwHhcNMjYwMzI2MTgxMTI5
# WhcNMzEwMzI2MTgxMTI5WjBaMQswCQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9z
# b2Z0IENvcnBvcmF0aW9uMSswKQYDVQQDEyJNaWNyb3NvZnQgSUQgVmVyaWZpZWQg
# Q1MgQU9DIENBIDA0MIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAylX6
# yNvoCTDP9G0OTlSjXbzgEsy21FDL17n/lZe2BrqHz2mR1aN4DBxeYp0/hjEqSHHy
# GfarV1NVBuvK8vLzW0LTi+DZt9In16aiNfgcogFiztWE9Fp8xu1zzrqE3nlrDWb+
# RZo8QrEXgWb8s8swsl2W7tREHycVkx+Hm1MLQIlva6jH/Xg4/8GIYhHzbXiVd2RX
# omw9s7Qh6/SYRXXfe125wh4EKEyKnNNl+cZUSrVBgWvvjrRwQY4if7sAZ805KruB
# Y6WY0Hiba5nWvrq9Qk9o35ViAf8qZ+7u1fbb1vcCWyWLfx9hLSdBjjVsSWe0xLvI
# 1j4p3Tjt5czz+1Lc0v5lQ1feB7nFmpbZrK2us0hvAaBCfOyDPEEm+735vzuNRYWJ
# FL/PViI+REtjuJMcojEn3veQjIrwrmK0T9oSr8e3oDzK1oAwwZMTC4KymTvYUTVD
# JvL5N8OW/UqIBzsiVYcchZvGhV3yMYKgxeEtIOG4W4Z85Y5kpQi5bpjGXFxRg46R
# drTaALt1RhRmLR7U0jVSr2aYAd2+Mp2qA5Gz3/loOOdt47eFZ3mrAYGYQtbK2SNj
# QpwgQX4Iy6tOKahCgFhKIcltitvSkpJB77eVWhNWnN2LfqMojszEue7V8EAySxry
# 4PzlxTtFTb3Mw53XyH12BMQf2m9j7jEsHeVSATsCAwEAAaOCAdwwggHYMA4GA1Ud
# DwEB/wQEAwIBhjAQBgkrBgEEAYI3FQEEAwIBADAdBgNVHQ4EFgQUayVB3vtrfP0Y
# gAotf492XapzPbgwVAYDVR0gBE0wSzBJBgRVHSAAMEEwPwYIKwYBBQUHAgEWM2h0
# dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvRG9jcy9SZXBvc2l0b3J5Lmh0
# bTAZBgkrBgEEAYI3FAIEDB4KAFMAdQBiAEMAQTASBgNVHRMBAf8ECDAGAQH/AgEA
# MB8GA1UdIwQYMBaAFNlBKbAPD2Ns72nX9c0pnqRIajDmMHAGA1UdHwRpMGcwZaBj
# oGGGX2h0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY3JsL01pY3Jvc29m
# dCUyMElEJTIwVmVyaWZpZWQlMjBDb2RlJTIwU2lnbmluZyUyMFBDQSUyMDIwMjEu
# Y3JsMH0GCCsGAQUFBwEBBHEwbzBtBggrBgEFBQcwAoZhaHR0cDovL3d3dy5taWNy
# b3NvZnQuY29tL3BraW9wcy9jZXJ0cy9NaWNyb3NvZnQlMjBJRCUyMFZlcmlmaWVk
# JTIwQ29kZSUyMFNpZ25pbmclMjBQQ0ElMjAyMDIxLmNydDANBgkqhkiG9w0BAQwF
# AAOCAgEABtVQXlR01UQZY5XGQ9yIjMcD8jI0MizWhJ1buZjg5toUQSXx/BrASwE5
# qxwHPBeO45pOQp6VD4iILgm8OmfylY+A7KIqttvDUizC3sBXxjK4u7sDRiyEguXH
# KfL1HQAwxCLEtnRPkCPTsJA6b917lA+3foQIHC1XDDpdQLHxGbbGXp4Rr0mFK5vx
# bi6tAahBi/RlzOXPh6PavKPlZ/0vhlkDdsvoJETtebNJCNOZ1Kav3Tg+K4va4FbO
# rYqRHdGGahoA/gmTYmmVqw0zkGzT53HdhfajrFGttJomK7qE+T8CQGiPkEIkxNmS
# XjCTpDqc4U1IKlTGcGYnRFGSgqrnWnkANPFsJ5EDHysh82lPI+PFC3FOIVMLzLL+
# 30rqznvRgHUUAj7xfFnEiuaAx3vFVSTOLb+iigpvdR6i8fSWpgYESOkdkn2N57tu
# hBs57tKwoP++vc/MVpuD1XAtmWi+lZSlahadTbDfGKjMn+bfm2xlW9PZ6BSnCRv1
# MMhpcUZkAZX3gVEMef8rZc2c7BJ4ayRfX0wH43vI9znV+ZRJ3j0xUC0Zb82RQalF
# 5yHkCr93x0IwvZtn6P2dNQyCP6qd3fC4RlVFtAQhtOH0cByTR/Iqqghv6qHzL/pM
# ptgMQQ5x8zYEYy+tCThYgYIrq7y4WEDYQfeSlqIxQOrIUJ4IJDEwggeeMIIFhqAD
# AgECAhMzAAAAB4ejNKN7pY4cAAAAAAAHMA0GCSqGSIb3DQEBDAUAMHcxCzAJBgNV
# BAYTAlVTMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xSDBGBgNVBAMT
# P01pY3Jvc29mdCBJZGVudGl0eSBWZXJpZmljYXRpb24gUm9vdCBDZXJ0aWZpY2F0
# ZSBBdXRob3JpdHkgMjAyMDAeFw0yMTA0MDEyMDA1MjBaFw0zNjA0MDEyMDE1MjBa
# MGMxCzAJBgNVBAYTAlVTMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24x
# NDAyBgNVBAMTK01pY3Jvc29mdCBJRCBWZXJpZmllZCBDb2RlIFNpZ25pbmcgUENB
# IDIwMjEwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQCy8MCvGYgo4t1U
# ekxJbGkIVQm0Uv96SvjB6yUo92cXdylN65Xy96q2YpWCiTas7QPTkGnK9QMKDXB2
# ygS27EAIQZyAd+M8X+dmw6SDtzSZXyGkxP8a8Hi6EO9Zcwh5A+wOALNQbNO+iLvp
# gOnEM7GGB/wm5dYnMEOguua1OFfTUITVMIK8faxkP/4fPdEPCXYyy8NJ1fmskNhW
# 5HduNqPZB/NkWbB9xxMqowAeWvPgHtpzyD3PLGVOmRO4ka0WcsEZqyg6efk3JiV/
# TEX39uNVGjgbODZhzspHvKFNU2K5MYfmHh4H1qObU4JKEjKGsqqA6RziybPqhvE7
# 4fEp4n1tiY9/ootdU0vPxRp4BGjQFq28nzawuvaCqUUF2PWxh+o5/TRCb/cHhcYU
# 8Mr8fTiS15kRmwFFzdVPZ3+JV3s5MulIf3II5FXeghlAH9CvicPhhP+VaSFW3Da/
# azROdEm5sv+EUwhBrzqtxoYyE2wmuHKws00x4GGIx7NTWznOm6x/niqVi7a/mxnn
# MvQq8EMse0vwX2CfqM7Le/smbRtsEeOtbnJBbtLfoAsC3TdAOnBbUkbUfG78VRcl
# sE7YDDBUbgWt75lDk53yi7C3n0WkHFU4EZ83i83abd9nHWCqfnYa9qIHPqjOiuAg
# SOf4+FRcguEBXlD9mAInS7b6V0UaNwIDAQABo4ICNTCCAjEwDgYDVR0PAQH/BAQD
# AgGGMBAGCSsGAQQBgjcVAQQDAgEAMB0GA1UdDgQWBBTZQSmwDw9jbO9p1/XNKZ6k
# SGow5jBUBgNVHSAETTBLMEkGBFUdIAAwQTA/BggrBgEFBQcCARYzaHR0cDovL3d3
# dy5taWNyb3NvZnQuY29tL3BraW9wcy9Eb2NzL1JlcG9zaXRvcnkuaHRtMBkGCSsG
# AQQBgjcUAgQMHgoAUwB1AGIAQwBBMA8GA1UdEwEB/wQFMAMBAf8wHwYDVR0jBBgw
# FoAUyH7SaoUqG8oZmAQHJ89QEE9oqKIwgYQGA1UdHwR9MHsweaB3oHWGc2h0dHA6
# Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY3JsL01pY3Jvc29mdCUyMElkZW50
# aXR5JTIwVmVyaWZpY2F0aW9uJTIwUm9vdCUyMENlcnRpZmljYXRlJTIwQXV0aG9y
# aXR5JTIwMjAyMC5jcmwwgcMGCCsGAQUFBwEBBIG2MIGzMIGBBggrBgEFBQcwAoZ1
# aHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9wcy9jZXJ0cy9NaWNyb3NvZnQl
# MjBJZGVudGl0eSUyMFZlcmlmaWNhdGlvbiUyMFJvb3QlMjBDZXJ0aWZpY2F0ZSUy
# MEF1dGhvcml0eSUyMDIwMjAuY3J0MC0GCCsGAQUFBzABhiFodHRwOi8vb25lb2Nz
# cC5taWNyb3NvZnQuY29tL29jc3AwDQYJKoZIhvcNAQEMBQADggIBAH8lKp7+1Kvq
# 3WYK21cjTLpebJDjW4ZbOX3HD5ZiG84vjsFXT0OB+eb+1TiJ55ns0BHluC6itMI2
# vnwc5wDW1ywdCq3TAmx0KWy7xulAP179qX6VSBNQkRXzReFyjvF2BGt6FvKFR/im
# R4CEESMAG8hSkPYso+GjlngM8JPn/ROUrTaeU/BRu/1RFESFVgK2wMz7fU4VTd8N
# XwGZBe/mFPZG6tWwkdmA/jLbp0kNUX7elxu2+HtHo0QO5gdiKF+YTYd1BGrmNG8s
# TURvn09jAhIUJfYNotn7OlThtfQjXqe0qrimgY4Vpoq2MgDW9ESUi1o4pzC1zTgI
# GtdJ/IvY6nqa80jFOTg5qzAiRNdsUvzVkoYP7bi4wLCj+ks2GftUct+fGUxXMdBU
# v5sdr0qFPLPB0b8vq516slCfRwaktAxK1S40MCvFbbAXXpAZnU20FaAoDwqq/jwz
# wd8Wo2J83r7O3onQbDO9TyDStgaBNlHzMMQgl95nHBYMelLEHkUnVVVTUsgC0Huj
# 09duNfMaJ9ogxhPNThgq3i8w3DAGZ61AMeF0C1M+mU5eucj1Ijod5O2MMPeJQ3/v
# KBtqGZg4eTtUHt/BPjN74SsJsyHqAdXVS5c+ItyKWg3Eforhox9k3WgtWTpgV4gk
# SiS4+A09roSdOI4vrRw+p+fL4WrxSK5nMYIXMjCCFy4CAQEwcTBaMQswCQYDVQQG
# EwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSswKQYDVQQDEyJN
# aWNyb3NvZnQgSUQgVmVyaWZpZWQgQ1MgQU9DIENBIDA0AhMzAAdtUPzn8fi/cXV9
# AAAAB21QMA0GCWCGSAFlAwQCAQUAoF4wEAYKKwYBBAGCNwIBDDECMAAwGQYJKoZI
# hvcNAQkDMQwGCisGAQQBgjcCAQQwLwYJKoZIhvcNAQkEMSIEIDrxYznogvvOjUha
# Q4Fc4QRwu2TzpQgsTQfH9vMil5VbMA0GCSqGSIb3DQEBAQUABIIBgId3HRTE5t+i
# B6o7dHxxymwqJbCTIsd+rCxGeQ1tzdC0gokWybxQmuak6+/DnsephImQSOldSF/1
# rkcZWfKmuiW17cvZlg9SXVsBYSA0isUgdmZ39OgAP0s6WDwSdRCYAHwCpXZsoNn7
# TYQf7QHN4gXQIiU98tfWEk0pd/hTLI3eLCDksMct4ZYRz7TiRhnmwqR5O9EAxmLN
# zQmKHLpvuibktRrTGGotWyohDWxgrUOoGvadLjhTfMTHX2m1gajRwEXDP9N4afty
# kjQtqbTjIaeH531DT68DaW7v6AuRTgnv8CM1Yu2O7GtEIxp1UUQvTlp2zokMZWZL
# 78atw7ccJOtPTYQ4dca514xjEdg6LhwyKNWgysCj6eL7FZxco9Kn7l7GpQlXF1XX
# 56ERHTdUZzByhsJDPqDZ1N6reFiCOB6pFwV2vyWk5k0990GvsijbAisoScds0GC4
# fUwJpLHZxwX0c6smG5G3YurJ7L+msOmtot35/fqhes3jicia2tFCN6GCFLIwghSu
# BgorBgEEAYI3AwMBMYIUnjCCFJoGCSqGSIb3DQEHAqCCFIswghSHAgEDMQ8wDQYJ
# YIZIAWUDBAIBBQAwggFqBgsqhkiG9w0BCRABBKCCAVkEggFVMIIBUQIBAQYKKwYB
# BAGEWQoDATAxMA0GCWCGSAFlAwQCAQUABCD2UR/jjIurUEOvN+oGFru4h7SpXBjs
# uMwKTR2kTadBxAIGaprL+p/PGBMyMDI2MTAwMTA3MjI0MC4xMjhaMASAAgH0oIHp
# pIHmMIHjMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UE
# BxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMS0wKwYD
# VQQLEyRNaWNyb3NvZnQgSXJlbGFuZCBPcGVyYXRpb25zIExpbWl0ZWQxJzAlBgNV
# BAsTHm5TaGllbGQgVFNTIEVTTjo3QTFBLTA1RTAtRDk0NzE1MDMGA1UEAxMsTWlj
# cm9zb2Z0IFB1YmxpYyBSU0EgVGltZSBTdGFtcGluZyBBdXRob3JpdHmggg8pMIIH
# gjCCBWqgAwIBAgITMwAAAAXlzw//Zi7JhwAAAAAABTANBgkqhkiG9w0BAQwFADB3
# MQswCQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMUgw
# RgYDVQQDEz9NaWNyb3NvZnQgSWRlbnRpdHkgVmVyaWZpY2F0aW9uIFJvb3QgQ2Vy
# dGlmaWNhdGUgQXV0aG9yaXR5IDIwMjAwHhcNMjAxMTE5MjAzMjMxWhcNMzUxMTE5
# MjA0MjMxWjBhMQswCQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBv
# cmF0aW9uMTIwMAYDVQQDEylNaWNyb3NvZnQgUHVibGljIFJTQSBUaW1lc3RhbXBp
# bmcgQ0EgMjAyMDCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBAJ5851Jj
# /eDFnwV9Y7UGIqMcHtfnlzPREwW9ZUZHd5HBXXBvf7KrQ5cMSqFSHGqg2/qJhYqO
# QxwuEQXG8kB41wsDJP5d0zmLYKAY8Zxv3lYkuLDsfMuIEqvGYOPURAH+Ybl4SJEE
# Snt0MbPEoKdNihwM5xGv0rGofJ1qOYSTNcc55EbBT7uq3wx3mXhtVmtcCEr5ZKTk
# KKE1CxZvNPWdGWJUPC6e4uRfWHIhZcgCsJ+sozf5EeH5KrlFnxpjKKTavwfFP6Xa
# GZGWUG8TZaiTogRoAlqcevbiqioUz1Yt4FRK53P6ovnUfANjIgM9JDdJ4e0qiDRm
# 5sOTiEQtBLGd9Vhd1MadxoGcHrRCsS5rO9yhv2fjJHrmlQ0EIXmp4DhDBieKUGR+
# eZ4CNE3ctW4uvSDQVeSp9h1SaPV8UWEfyTxgGjOsRpeexIveR1MPTVf7gt8hY64X
# NPO6iyUGsEgt8c2PxF87E+CO7A28TpjNq5eLiiunhKbq0XbjkNoU5JhtYUrlmAbp
# xRjb9tSreDdtACpm3rkpxp7AQndnI0Shu/fk1/rE3oWsDqMX3jjv40e8KN5YsJBn
# czyWB4JyeeFMW3JBfdeAKhzohFe8U5w9WuvcP1E8cIxLoKSDzCCBOu0hWdjzKNu8
# Y5SwB1lt5dQhABYyzR3dxEO/T1K/BVF3rV69AgMBAAGjggIbMIICFzAOBgNVHQ8B
# Af8EBAMCAYYwEAYJKwYBBAGCNxUBBAMCAQAwHQYDVR0OBBYEFGtpKDo1L0hjQM97
# 2K9J6T7ZPdshMFQGA1UdIARNMEswSQYEVR0gADBBMD8GCCsGAQUFBwIBFjNodHRw
# Oi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL0RvY3MvUmVwb3NpdG9yeS5odG0w
# EwYDVR0lBAwwCgYIKwYBBQUHAwgwGQYJKwYBBAGCNxQCBAweCgBTAHUAYgBDAEEw
# DwYDVR0TAQH/BAUwAwEB/zAfBgNVHSMEGDAWgBTIftJqhSobyhmYBAcnz1AQT2io
# ojCBhAYDVR0fBH0wezB5oHegdYZzaHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3Br
# aW9wcy9jcmwvTWljcm9zb2Z0JTIwSWRlbnRpdHklMjBWZXJpZmljYXRpb24lMjBS
# b290JTIwQ2VydGlmaWNhdGUlMjBBdXRob3JpdHklMjAyMDIwLmNybDCBlAYIKwYB
# BQUHAQEEgYcwgYQwgYEGCCsGAQUFBzAChnVodHRwOi8vd3d3Lm1pY3Jvc29mdC5j
# b20vcGtpb3BzL2NlcnRzL01pY3Jvc29mdCUyMElkZW50aXR5JTIwVmVyaWZpY2F0
# aW9uJTIwUm9vdCUyMENlcnRpZmljYXRlJTIwQXV0aG9yaXR5JTIwMjAyMC5jcnQw
# DQYJKoZIhvcNAQEMBQADggIBAF+Idsd+bbVaFXXnTHho+k7h2ESZJRWluLE0Oa/p
# O+4ge/XEizXvhs0Y7+KVYyb4nHlugBesnFqBGEdC2IWmtKMyS1OWIviwpnK3aL5J
# edwzbeBF7POyg6IGG/XhhJ3UqWeWTO+Czb1c2NP5zyEh89F72u9UIw+IfvM9lzDm
# c2O2END7MPnrcjWdQnrLn1Ntday7JSyrDvBdmgbNnCKNZPmhzoa8PccOiQljjTW6
# GePe5sGFuRHzdFt8y+bN2neF7Zu8hTO1I64XNGqst8S+w+RUdie8fXC1jKu3m9KG
# IqF4aldrYBamyh3g4nJPj/LR2CBaLyD+2BuGZCVmoNR/dSpRCxlot0i79dKOChmo
# ONqbMI8m04uLaEHAv4qwKHQ1vBzbV/nG89LDKbRSSvijmwJwxRxLLpMQ/u4xXxFf
# R4f/gksSkbJp7oqLwliDm/h+w0aJ/U5ccnYhYb7vPKNMN+SZDWycU5ODIRfyoGl5
# 9BsXR/HpRGtiJquOYGmvA/pk5vC1lcnbeMrcWD/26ozePQ/TWfNXKBOmkFpvPE8C
# H+EeGGWzqTCjdAsno2jzTeNSxlx3glDGJgcdz5D/AAxw9Sdgq/+rY7jjgs7X6fqP
# TXPmaCAJKVHAP19oEjJIBwD1LyHbaEgBxFCogYSOiUIr0Xqcr1nJfiWG2GwYe6Zo
# AF1bMIIHnzCCBYegAwIBAgITMwAAAFtKtY1BMm3cdAAAAAAAWzANBgkqhkiG9w0B
# AQwFADBhMQswCQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0
# aW9uMTIwMAYDVQQDEylNaWNyb3NvZnQgUHVibGljIFJTQSBUaW1lc3RhbXBpbmcg
# Q0EgMjAyMDAeFw0yNjAxMDgxODU5MDVaFw0yNzAxMDcxODU5MDVaMIHjMQswCQYD
# VQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEe
# MBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMS0wKwYDVQQLEyRNaWNyb3Nv
# ZnQgSXJlbGFuZCBPcGVyYXRpb25zIExpbWl0ZWQxJzAlBgNVBAsTHm5TaGllbGQg
# VFNTIEVTTjo3QTFBLTA1RTAtRDk0NzE1MDMGA1UEAxMsTWljcm9zb2Z0IFB1Ymxp
# YyBSU0EgVGltZSBTdGFtcGluZyBBdXRob3JpdHkwggIiMA0GCSqGSIb3DQEBAQUA
# A4ICDwAwggIKAoICAQCQVMwW255Q13ntAdCg+RuP+O+bYRcn3LQsrhEk1kF75S4u
# Fsf7XdqlHXquInXnoOlVoYjh37t8CVeE1BkkbaofQnK9QZogSr/YrhaYB8iAbuUM
# d/GbMcJRXl1UvmaiSSp10WwzUHXGEqAv+nNIUCfzx+dAwUQ0JD11cMhYsy60R/QJ
# ayXlIOwSnk9t837UvPyjiS7xBGxzheqUjmN2Vaa2VFm1o1sEU5qB2kPxPL61rSzc
# hCfm9PPVVtSJK2t7eBkweVm8twi9Sts2JwMQSL2n7CjBco/Trlx3EzyjA6BUjHmp
# hvTCjjG+rqBtT43Zw4LCz+hDjEUs6yy+4xA9ZmwfUUnfX4bcvh0K+r2YLAZ+qFMv
# mE6TVS7JMHbVDPNlmAJD87ZTrdwIi9Ksle/1N4/7qt7xzIzzNMNN+NDOezXotIOA
# QnDLdHW6qHPdVYAm9/9+rB0ADaJ7Z9RzhdqC5PNfdEEUuN4rB1a2vB/LH+fhpaiG
# LGIgil9OB2Yjs2VvNup1SOnfvvJck3lpqY/dFGvbj2yYVY8BN6IerTuddMkqpkjE
# ixDdO6dyG3txOgQG9sPd61s29uvnaUrYWyheJAKaH6gbFj1+DBLRykjn7T5lUwkO
# O7YIa1bh4mvY2Ph7I9NZuCluFrZJlZty+oTGRAjGuLIzMQF8/m1/wCYVk3uk2QID
# AQABo4IByzCCAccwHQYDVR0OBBYEFO/y6lJVlmIVyXV8IGCseG/Br9K2MB8GA1Ud
# IwQYMBaAFGtpKDo1L0hjQM972K9J6T7ZPdshMGwGA1UdHwRlMGMwYaBfoF2GW2h0
# dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY3JsL01pY3Jvc29mdCUyMFB1
# YmxpYyUyMFJTQSUyMFRpbWVzdGFtcGluZyUyMENBJTIwMjAyMC5jcmwweQYIKwYB
# BQUHAQEEbTBrMGkGCCsGAQUFBzAChl1odHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20v
# cGtpb3BzL2NlcnRzL01pY3Jvc29mdCUyMFB1YmxpYyUyMFJTQSUyMFRpbWVzdGFt
# cGluZyUyMENBJTIwMjAyMC5jcnQwDAYDVR0TAQH/BAIwADAWBgNVHSUBAf8EDDAK
# BggrBgEFBQcDCDAOBgNVHQ8BAf8EBAMCB4AwZgYDVR0gBF8wXTBRBgwrBgEEAYI3
# TIN9AQEwQTA/BggrBgEFBQcCARYzaHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3Br
# aW9wcy9Eb2NzL1JlcG9zaXRvcnkuaHRtMAgGBmeBDAEEAjANBgkqhkiG9w0BAQwF
# AAOCAgEAAB/s3flyoeDsV2DFhZrYIpVwEBnLTowlAdcP7gYgvzl3B9yGuP123VIS
# sxW2ok2yBOr2GSndaeLu5yji5GsMpgDFcrjuy0peqyyrbWSMi4Vo0ytM1zs9LuMS
# 6vfm0bQRCibwOrA+ZycB9SDus9WIs8riEaGpTAp261IsX1sUJ+EwJje7fbpPl9hV
# E4RGt3sM0cIbRvscGgGyzJMUZkduCZ313dVcSqPdPpu1s7qL/elLoMecGXXsIiCJ
# tWVk4+JQiR7qeu/S3Dmu7QMSTIqVWkpbUB/X5vUzinM5X8bVrgXC1OHbmX6sILCC
# 7B+zzJHF9c8EM0A9MgLT4Z2M/SjRtduW1/oopTntUvER6r9m2waTKWqOJHFL0COn
# TICkbxZptXi24UjTkKZQzExg9bTVXTRpCPeo1Lvra6FI1jDIuOk0HwQB8bQ06UYS
# Lv/O7wFUPGekR4RcXrM+BHeSU4WiEEQMuhnDvyZPkMw86GdGq0SJCLBie62YDlQI
# 8fXLX8PJR/UX43MAd8HRgWDTDVSakKVGotk2nXX+aV802RByKixBed0qwYyHiJ6E
# Kz+1OVZV4jELMXsC3SDawBNpdk0dygYpG/kUEcoG06fI49sogtDQlMBvivp3YJTe
# UTG14xVumimufV6vm/F8yvwyvgCbYDqR4Cb/EK5OtgPrcDlSzqYxggPUMIID0AIB
# ATB4MGExCzAJBgNVBAYTAlVTMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRp
# b24xMjAwBgNVBAMTKU1pY3Jvc29mdCBQdWJsaWMgUlNBIFRpbWVzdGFtcGluZyBD
# QSAyMDIwAhMzAAAAW0q1jUEybdx0AAAAAABbMA0GCWCGSAFlAwQCAQUAoIIBLTAa
# BgkqhkiG9w0BCQMxDQYLKoZIhvcNAQkQAQQwLwYJKoZIhvcNAQkEMSIEIL5usMCn
# /Fg3qqT9w5kfcnMXrEhs1y+2T4t6I4fp0g7qMIHdBgsqhkiG9w0BCRACLzGBzTCB
# yjCBxzCBoAQgLzEDVV2dG9McZRsPF/9yBMmzm7k+muVtXetQlvnBg+8wfDBlpGMw
# YTELMAkGA1UEBhMCVVMxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEy
# MDAGA1UEAxMpTWljcm9zb2Z0IFB1YmxpYyBSU0EgVGltZXN0YW1waW5nIENBIDIw
# MjACEzMAAABbSrWNQTJt3HQAAAAAAFswIgQgvu7HQqB2v7fRnWu6Wu/a+1U48d2Y
# sBuggne994ioqXAwDQYJKoZIhvcNAQELBQAEggIAiY14EFmdwrfb8nsXAF3BF6TL
# ueKHNyV58PWPUPXh4atl3DCtePRDle4H8IKLi+bL0QyEFvhsNAAQ33ZDjvt+10LO
# PcuSkvsA0trAbVLQqhK397vTdjqCUcDHW0pJeQ+cgY0FDfeTm5AY2Fhzv22p2BtW
# IPi2JFoiW7fc+m+OxGvCqegZFAxYmcO7B2S1rB3KcjKUjq3Uq402BYMN1n7VdbMB
# h6tW08eVlXw+ZlUihubzCBKmzy2jmHy5BfGXTiwppApx2ihb8rCgwsENP7ukopNM
# c9m6gkLRDxuO+fB9bxEUzn28zn0nun2u3x5zkN4Pn83QNf7L3rD5RKGStd0QpyKu
# GYLXwx9/tSXchjuN3Q4dqDtvJWc2PRFcEYXF8d1aKISkZDyKBIJH086tHx8FCXFd
# bArxD2oz5XB6kG9dXLZ5of4yY6LG7yGpL6Plw/fGomV7/1NMDZn3fXFYUfIYUuAW
# 1xXXVXgk1WXUvsw6N7HeoM1v9DE8EuE3LFMMLZwdfgEXPxOIoUAHmfQwu4KjjSxD
# xSti7ob4IQp+s62P6jnO6kdQ+6iAuuWVRQnYxUmCjb68+ye6cKSBS76vvmjBuMfN
# crQjrB68i5VNaI4e8BFm/16nv3enXnnyQFHD+8PWWDGEKT1VtzYs2QtntwcpbFrm
# X6kZmRj6vo/16leGuSI=
# SIG # End signature block
