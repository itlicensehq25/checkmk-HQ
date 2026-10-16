# ==========================================================
# update_checks.ps1 - Auto-update script Checkmk dari GitHub
# Dijalankan oleh Scheduled Task "Checkmk_Auto_Update" (SYSTEM).
# Cara kerja:
#   1. Ambil daftar file dari  windows/local_checks/manifest.txt  (jika ada),
#      kalau tidak ada dipakai daftar bawaan di bawah.
#   2. Unduh tiap file ke folder sementara, bandingkan hash (SHA256)
#      dengan file di PC. Hanya yang BERBEDA yang diganti.
#   3. Perbarui dirinya sendiri (update_checks.ps1) jika ada versi baru.
# Log: C:\ProgramData\checkmk\agent\log_custom\update_checks.log
# ==========================================================
param(
    [string]$GithubUser = 'itlicensehq25',
    [string]$GithubRepo = 'checkmk-HQ',
    [string]$Branch     = 'main'
)

$ErrorActionPreference = 'Stop'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}

$BaseUrl   = "https://raw.githubusercontent.com/$GithubUser/$GithubRepo/$Branch/windows"
$AgentRoot = 'C:\ProgramData\checkmk\agent'
$LocalDir  = Join-Path $AgentRoot 'local'
$PluginDir = Join-Path $AgentRoot 'plugins'
$LogDir    = Join-Path $AgentRoot 'log_custom'
$LogFile   = Join-Path $LogDir 'update_checks.log'
$TempDir   = Join-Path $env:TEMP 'checkmk_update'

# File yang harus masuk folder PLUGINS (bukan local)
$PluginFiles = @('mk_inventory.ps1')

# Daftar bawaan jika manifest.txt tidak ada di GitHub
$DefaultList = @(
    'battery_health.ps1', 'cpu_info.ps1', 'disk_nvme_health.ps1', 'fan_health.ps1',
    'info_network.ps1', 'info_OS_office.ps1', 'ram_health.ps1', 'ram_usage.ps1',
    'remote_apps.ps1', 'storage_usage.ps1', 'network_internet.ps1', 'network_local.ps1',
    'network_disconnect.ps1', 'mk_inventory.ps1'
)

foreach ($d in @($LogDir, $LocalDir, $PluginDir, $TempDir)) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
}

function Write-Log {
    param([string]$Msg)
    $line = '{0}  {1}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $Msg
    try {
        if ((Test-Path $LogFile) -and ((Get-Item $LogFile).Length -gt 200KB)) {
            Get-Content $LogFile -Tail 200 | Set-Content $LogFile -Encoding UTF8
        }
        Add-Content -Path $LogFile -Value $line -Encoding UTF8
    } catch {}
}

# Unduh $Url ke file sementara; ganti $Dest hanya jika isinya berbeda. Return: 'updated' / 'same'
function Sync-File {
    param([string]$Url, [string]$Dest)
    $tmp = Join-Path $TempDir ([IO.Path]::GetFileName($Dest) + '.new')
    Invoke-WebRequest -Uri $Url -OutFile $tmp -UseBasicParsing
    if (-not (Test-Path $tmp) -or (Get-Item $tmp).Length -eq 0) { throw 'file kosong' }

    $same = $false
    if (Test-Path $Dest) {
        $same = ((Get-FileHash $tmp -Algorithm SHA256).Hash -eq (Get-FileHash $Dest -Algorithm SHA256).Hash)
    }
    if ($same) { Remove-Item $tmp -Force; return 'same' }

    Copy-Item $tmp $Dest -Force
    Remove-Item $tmp -Force
    return 'updated'
}

# ---------- 1. Daftar file ----------
$files = @($DefaultList)
try {
    $manifestTmp = Join-Path $TempDir 'manifest.txt'
    Invoke-WebRequest -Uri "$BaseUrl/local_checks/manifest.txt" -OutFile $manifestTmp -UseBasicParsing
    $fromManifest = @(Get-Content $manifestTmp | ForEach-Object { $_.Trim() } |
        Where-Object { $_ -and -not $_.StartsWith('#') -and $_ -match '^[A-Za-z0-9_.\-]+\.ps1$' })
    if ($fromManifest.Count -gt 0) { $files = $fromManifest }
    Remove-Item $manifestTmp -Force -ErrorAction SilentlyContinue
} catch {
    # tidak ada manifest -> pakai daftar bawaan
}

# ---------- 2. Sinkronkan ----------
$updated = 0
$failed  = 0
foreach ($f in $files) {
    $dest = Join-Path $LocalDir $f
    if ($PluginFiles -contains $f) { $dest = Join-Path $PluginDir $f }
    try {
        $r = Sync-File -Url "$BaseUrl/local_checks/$f" -Dest $dest
        if ($r -eq 'updated') { $updated++; Write-Log "DIPERBARUI: $f" }
    } catch {
        $failed++
        Write-Log "GAGAL: $f ($($_.Exception.Message))"
    }
}
Write-Log "Selesai. diperbarui=$updated gagal=$failed total=$($files.Count)"

# ---------- 3. Perbarui diri sendiri ----------
try {
    if ($PSCommandPath) {
        $r = Sync-File -Url "$BaseUrl/update_checks.ps1" -Dest $PSCommandPath
        if ($r -eq 'updated') { Write-Log 'update_checks.ps1 sendiri diperbarui (berlaku di jalan berikutnya)' }
    }
} catch {}
