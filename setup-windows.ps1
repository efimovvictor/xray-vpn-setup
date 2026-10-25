<#
.SYNOPSIS
    Installs Xray-core as a local (loopback-only) proxy from a VLESS + Reality link
    and points Claude Code at it.

.DESCRIPTION
    What the script does:
      1. Downloads the latest Xray-core release into %USERPROFILE%\xray.
      2. Builds config.json from the vless:// link (UUID, host, keys, SNI, flow - all taken from the link).
      3. Creates a hidden-start launcher and, unless -NoAutostart, a Startup shortcut.
      4. Merges HTTPS_PROXY / HTTP_PROXY / NO_PROXY into %USERPROFILE%\.claude\settings.json
         (existing keys are preserved; the file is never blindly overwritten).
      5. Starts the proxy and verifies it with a real HTTPS request.

    What it does NOT do:
      * no admin rights needed, no services, no drivers, no TUN
      * no route changes, no system proxy, no firewall rules
      * the proxy listens on 127.0.0.1 only, so a corporate/office VPN keeps working as usual

.PARAMETER Link
    vless://UUID@HOST:PORT?type=tcp&security=reality&pbk=...&sni=...&sid=...&flow=...
    If omitted: an existing config is kept; otherwise you are prompted to paste one.

.PARAMETER Port
    Local proxy port (HTTP + SOCKS5 on the same port). Default: 12345.

.PARAMETER InstallDir
    Where Xray lives. Default: %USERPROFILE%\xray

.PARAMETER NoAutostart
    Do not create the Startup shortcut.

.PARAMETER NoClaude
    Do not touch %USERPROFILE%\.claude\settings.json.

.PARAMETER Update
    Re-download Xray-core even if it is already installed. config.json is kept.

.PARAMETER Uninstall
    Stop the proxy, remove autostart, launcher and the install folder.
    The proxy entries this script added to .claude\settings.json are removed too.

.EXAMPLE
    .\setup-windows.ps1 -Link "vless://...."

.EXAMPLE
    .\setup-windows.ps1 -Port 10808

.EXAMPLE
    .\setup-windows.ps1 -Uninstall
#>

[CmdletBinding()]
param(
    [string]$Link = '',
    [int]$Port = 12345,
    [string]$InstallDir = '',
    [switch]$NoAutostart,
    [switch]$NoClaude,
    [switch]$Update,
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'

# TLS 1.2 for Invoke-WebRequest on older Windows builds
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }

if (-not $InstallDir) { $InstallDir = Join-Path $env:USERPROFILE 'xray' }

$XrayExe      = Join-Path $InstallDir 'xray.exe'
$ConfigPath   = Join-Path $InstallDir 'config.json'
$LauncherPath = Join-Path $InstallDir 'start-xray.vbs'
$ClaudePath   = Join-Path $env:USERPROFILE '.claude\settings.json'
$NoProxyList  = 'localhost,127.0.0.1,::1'
$ProxyUrl     = 'http://127.0.0.1:' + $Port

# ---------------------------------------------------------------- output helpers

function Say  { param([string]$Text) Write-Host "==> $Text" -ForegroundColor Cyan }
function Note { param([string]$Text) Write-Host "    $Text" }
function Warn { param([string]$Text) Write-Host "    ! $Text" -ForegroundColor Yellow }

function Get-ShortcutPath {
    $dir = [Environment]::GetFolderPath('Startup')
    if (-not $dir) { $dir = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup' }
    return (Join-Path $dir 'XrayProxy.lnk')
}

# ---------------------------------------------------------------- JSON helpers

function Write-JsonFile {
    param([string]$Path, $Object)
    $json = $Object | ConvertTo-Json -Depth 20
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($Path, $json + [Environment]::NewLine, $utf8)
}

function Read-JsonFile {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $null }
    $raw = Get-Content -Path $Path -Raw -Encoding UTF8
    if (-not $raw -or -not $raw.Trim()) { return $null }
    return $raw | ConvertFrom-Json
}

# ---------------------------------------------------------------- config

function New-XrayConfig {
    param([string]$Link, [string]$Path, [int]$Port)

    $u = $null
    try { $u = [Uri]$Link } catch { throw 'Could not parse the link. Check that it is a complete vless:// URL.' }

    if ($u.Scheme -ne 'vless') { throw "Expected a vless:// link, got '$($u.Scheme)://'." }
    if (-not $u.UserInfo) { throw 'The link has no UUID (expected vless://UUID@HOST:PORT?...).' }
    if (-not $u.Host) { throw 'The link has no host.' }

    $query = @{}
    if ($u.Query) {
        foreach ($pair in $u.Query.TrimStart('?').Split('&')) {
            if (-not $pair) { continue }
            $kv = $pair.Split('=', 2)
            if ($kv.Count -eq 2) { $query[$kv[0]] = [Uri]::UnescapeDataString($kv[1]) }
        }
    }

    if (-not $query.ContainsKey('pbk')) { throw "The link has no 'pbk' parameter. Is it really a Reality link?" }
    if (-not $query.ContainsKey('sni')) { throw "The link has no 'sni' parameter. Is it really a Reality link?" }

    if ($query.ContainsKey('security') -and $query['security'] -ne 'reality') {
        throw "This script builds Reality configs only (link says security=$($query['security']))."
    }

    if ($u.Host -eq 'localhost' -or $u.Host -eq '127.0.0.1' -or $u.Host -eq '::1') {
        throw ('The link points at ' + $u.Host + ' instead of the server IP. ' +
               'Panels generate such links when they are opened through an SSH tunnel. ' +
               'Replace the host in the link with the real server IP and run the script again.')
    }

    $serverPort = 443
    if ($u.Port -gt 0) { $serverPort = $u.Port }

    $sid = ''
    if ($query.ContainsKey('sid')) { $sid = $query['sid'] }

    $fingerprint = 'chrome'
    if ($query.ContainsKey('fp') -and $query['fp']) { $fingerprint = $query['fp'] }

    $user = [ordered]@{ id = $u.UserInfo; encryption = 'none' }
    if ($query.ContainsKey('flow') -and $query['flow']) { $user['flow'] = $query['flow'] }

    $config = [ordered]@{
        log       = [ordered]@{ loglevel = 'warning' }
        inbounds  = @(
            [ordered]@{
                listen   = '127.0.0.1'
                port     = $Port
                protocol = 'mixed'
                settings = [ordered]@{ auth = 'noauth'; udp = $true }
            }
        )
        outbounds = @(
            [ordered]@{
                protocol       = 'vless'
                settings       = [ordered]@{
                    vnext = @(
                        [ordered]@{
                            address = $u.Host
                            port    = $serverPort
                            users   = @($user)
                        }
                    )
                }
                streamSettings = [ordered]@{
                    network         = 'tcp'
                    security        = 'reality'
                    realitySettings = [ordered]@{
                        serverName  = $query['sni']
                        fingerprint = $fingerprint
                        publicKey   = $query['pbk']
                        shortId     = $sid
                    }
                }
            }
        )
    }

    $dir = Split-Path -Parent $Path
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    Write-JsonFile -Path $Path -Object $config

    Note "server $($u.Host):$serverPort, SNI $($query['sni']), local port $Port"
}

function Test-XrayConfig {
    param([string]$Path)
    if (-not (Test-Path $XrayExe)) { throw "xray.exe not found at $XrayExe" }

    # native stderr must not become a terminating error under $ErrorActionPreference = 'Stop'
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & $XrayExe run -test -c $Path 2>&1
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previous
    }

    if ($code -ne 0) {
        $output | ForEach-Object { Warn $_ }
        throw 'The generated config is not valid (see above).'
    }
    Note 'config check: OK'
}

function Get-ConfigPort {
    param([string]$Path)
    $cfg = Read-JsonFile -Path $Path
    if ($cfg -and $cfg.inbounds -and $cfg.inbounds.Count -gt 0 -and $cfg.inbounds[0].port) {
        return [int]$cfg.inbounds[0].port
    }
    return 0
}

# ---------------------------------------------------------------- binary

function Install-XrayBinary {
    param([string]$Dir)

    $asset = ''
    switch ($env:PROCESSOR_ARCHITECTURE) {
        'ARM64' { $asset = 'Xray-windows-arm64-v8a.zip' }
        'AMD64' { $asset = 'Xray-windows-64.zip' }
        'x86'   { $asset = 'Xray-windows-32.zip' }
        default { throw "Unsupported architecture: $($env:PROCESSOR_ARCHITECTURE)" }
    }

    if (-not (Test-Path $Dir)) { New-Item -ItemType Directory -Force -Path $Dir | Out-Null }

    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }

    $url = 'https://github.com/XTLS/Xray-core/releases/latest/download/' + $asset
    $zip = Join-Path ([IO.Path]::GetTempPath()) ('xray-' + [guid]::NewGuid().ToString('N') + '.zip')

    Note "downloading $asset"
    Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
    try {
        Expand-Archive -Path $zip -DestinationPath $Dir -Force
    } finally {
        Remove-Item $zip -Force -ErrorAction SilentlyContinue
    }
    Note "unpacked into $Dir"
}

# ---------------------------------------------------------------- autostart

function Set-Launcher {
    param([string]$Dir, [string]$Launcher)

    $exePath = Join-Path $Dir 'xray.exe'
    $cfgPath = Join-Path $Dir 'config.json'
    $command = '"' + $exePath + '" run -c "' + $cfgPath + '"'
    $line = 'CreateObject("Wscript.Shell").Run "' + ($command -replace '"', '""') + '", 0, False'

    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($Launcher, $line + [Environment]::NewLine, $utf8)
    Note "launcher: $Launcher"

    if ($NoAutostart) {
        Note 'autostart: skipped (-NoAutostart)'
        return
    }

    $shortcut = Get-ShortcutPath
    $ws = New-Object -ComObject WScript.Shell
    $lnk = $ws.CreateShortcut($shortcut)
    $lnk.TargetPath = 'wscript.exe'
    $lnk.Arguments = '"' + $Launcher + '"'
    $lnk.WorkingDirectory = $Dir
    $lnk.WindowStyle = 7
    $lnk.Save()
    Note "autostart: $shortcut"
}

function Remove-Launcher {
    param([string]$Launcher)
    try {
        $shortcut = Get-ShortcutPath
        if (Test-Path $shortcut) {
            $ws = New-Object -ComObject WScript.Shell
            $lnk = $ws.CreateShortcut($shortcut)
            if ($lnk.Arguments -like ('*' + $Launcher + '*')) {
                Remove-Item $shortcut -Force
                Note "removed $shortcut"
            } else {
                Warn "left $shortcut alone (it points somewhere else)"
            }
        }
    } catch {
        Warn "could not inspect the Startup folder: $($_.Exception.Message)"
    }
    if (Test-Path $Launcher) {
        Remove-Item $Launcher -Force
        Note "removed $Launcher"
    }
}

# ---------------------------------------------------------------- claude code

function Set-ClaudeProxy {
    param([string]$Path, [string]$ProxyUrl)

    $dir = Split-Path -Parent $Path
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }

    $cfg = $null
    if (Test-Path $Path) {
        try {
            $cfg = Read-JsonFile -Path $Path
        } catch {
            $backup = $Path + '.bak-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
            Copy-Item $Path $backup -Force
            Warn "existing settings.json is not valid JSON; kept a copy at $backup"
            $cfg = $null
        }
    }
    if ($null -eq $cfg) { $cfg = New-Object psobject }

    if (-not $cfg.PSObject.Properties['env']) {
        Add-Member -InputObject $cfg -MemberType NoteProperty -Name env -Value (New-Object psobject)
    } elseif ($null -eq $cfg.env) {
        $cfg.env = New-Object psobject
    }

    $values = @{
        HTTPS_PROXY = $ProxyUrl
        HTTP_PROXY  = $ProxyUrl
        NO_PROXY    = $NoProxyList
    }
    foreach ($key in $values.Keys) {
        $value = $values[$key]
        if ($cfg.env.PSObject.Properties[$key]) { $cfg.env.$key = $value }
        else { Add-Member -InputObject $cfg.env -MemberType NoteProperty -Name $key -Value $value }
    }

    Write-JsonFile -Path $Path -Object $cfg
    Note "claude code proxy: $Path"
}

function Remove-ClaudeProxy {
    param([string]$Path, [string]$ProxyUrl)

    if (-not (Test-Path $Path)) { return }

    $cfg = $null
    try { $cfg = Read-JsonFile -Path $Path } catch { Warn "cannot parse $Path - left untouched"; return }
    if ($null -eq $cfg) { return }
    if (-not $cfg.PSObject.Properties['env'] -or $null -eq $cfg.env) { return }

    if ($cfg.env.PSObject.Properties['HTTPS_PROXY'] -and $cfg.env.HTTPS_PROXY -eq $ProxyUrl) {
        $cfg.env.PSObject.Properties.Remove('HTTPS_PROXY')
    }
    if ($cfg.env.PSObject.Properties['HTTP_PROXY'] -and $cfg.env.HTTP_PROXY -eq $ProxyUrl) {
        $cfg.env.PSObject.Properties.Remove('HTTP_PROXY')
    }
    if ($cfg.env.PSObject.Properties['NO_PROXY'] -and $cfg.env.NO_PROXY -eq $NoProxyList) {
        $cfg.env.PSObject.Properties.Remove('NO_PROXY')
    }
    if (@($cfg.env.PSObject.Properties | ForEach-Object { $_.Name }).Count -eq 0) {
        $cfg.PSObject.Properties.Remove('env')
    }

    if (@($cfg.PSObject.Properties | ForEach-Object { $_.Name }).Count -eq 0) {
        Remove-Item $Path -Force
        Note "removed $Path (it only held the proxy settings)"
    } else {
        Write-JsonFile -Path $Path -Object $cfg
        Note "removed proxy entries from $Path"
    }
}

# ---------------------------------------------------------------- process

function Restart-Xray {
    param([string]$Launcher)
    Stop-XrayProcess
    Start-Sleep -Milliseconds 500
    Start-Process -FilePath 'wscript.exe' -ArgumentList ('"' + $Launcher + '"') -WindowStyle Hidden
    Start-Sleep -Seconds 2
}

# Stop-Process returns before the OS releases the executable file, so wait for it to really exit.
function Stop-XrayProcess {
    $deadline = (Get-Date).AddSeconds(10)
    while ((Get-Process xray -ErrorAction SilentlyContinue) -and ((Get-Date) -lt $deadline)) {
        Get-Process xray -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 300
    }
}

function Remove-InstallDir {
    param([string]$Dir)
    if (-not (Test-Path $Dir)) { return }

    for ($attempt = 1; $attempt -le 10; $attempt++) {
        try {
            Remove-Item $Dir -Recurse -Force -ErrorAction Stop
            Note "removed $Dir"
            return
        } catch {
            if ($attempt -eq 10) {
                Warn "could not delete ${Dir}: $($_.Exception.Message)"
                Warn 'something still holds the files (antivirus scan, open window).'
                Warn 'close it or reboot, then delete the folder manually.'
                return
            }
            Start-Sleep -Milliseconds 700
        }
    }
}

function Test-Tunnel {
    param([string]$ProxyUrl)
    for ($i = 1; $i -le 8; $i++) {
        try {
            $r = Invoke-WebRequest -Uri 'https://api.ipify.org' -Proxy $ProxyUrl -UseBasicParsing -TimeoutSec 10
            if ($r.Content) { return $r.Content.Trim() }
        } catch {
            Start-Sleep -Seconds 1
        }
    }
    return $null
}

# ---------------------------------------------------------------- uninstall

trap {
    Write-Host ''
    Write-Host ('Error: ' + $_.Exception.Message) -ForegroundColor Red
    exit 1
}

if ($Uninstall) {
    Say 'Removing the Xray proxy'

    $cfgPort = Get-ConfigPort -Path $ConfigPath
    if ($cfgPort -gt 0) { $ProxyUrl = 'http://127.0.0.1:' + $cfgPort }

    Stop-XrayProcess
    Note 'process stopped'

    Remove-Launcher -Launcher $LauncherPath

    if (-not $NoClaude) { Remove-ClaudeProxy -Path $ClaudePath -ProxyUrl $ProxyUrl }

    Remove-InstallDir -Dir $InstallDir

    Say 'Done. Nothing else on this machine was changed.'
    return
}

# ---------------------------------------------------------------- install

Say 'Xray proxy setup'

# 1. config (first, so a bad link fails before anything is downloaded)
Say 'Configuring'
if ($Link) {
    New-XrayConfig -Link $Link -Path $ConfigPath -Port $Port
} elseif (Test-Path $ConfigPath) {
    $cfgPort = Get-ConfigPort -Path $ConfigPath
    if ($cfgPort -gt 0) { $Port = $cfgPort; $ProxyUrl = 'http://127.0.0.1:' + $Port }
    Note "existing config kept: $ConfigPath (local port $Port)"
    Note 'pass -Link "vless://..." to replace it'
} else {
    $Link = Read-Host 'Paste the vless:// link'
    if (-not $Link) { throw 'No link provided.' }
    New-XrayConfig -Link $Link -Path $ConfigPath -Port $Port
}

# 2. binary
if ((Test-Path $XrayExe) -and -not $Update) {
    Say 'Xray-core already present'
    Note $XrayExe
} else {
    Say 'Installing Xray-core'
    try {
        Install-XrayBinary -Dir $InstallDir
    } catch {
        if (Test-Path $XrayExe) {
            Warn "download failed ($($_.Exception.Message)) - using the existing binary"
        } else {
            throw "Could not download Xray-core: $($_.Exception.Message)"
        }
    }
}

Test-XrayConfig -Path $ConfigPath

# 3. launcher / autostart
Say 'Setting up autostart'
Set-Launcher -Dir $InstallDir -Launcher $LauncherPath

# 4. claude code
if ($NoClaude) {
    Say 'Claude Code settings: skipped (-NoClaude)'
} else {
    Say 'Configuring Claude Code'
    Set-ClaudeProxy -Path $ClaudePath -ProxyUrl $ProxyUrl
}

# 5. start + verify
Say 'Starting the proxy'
Restart-Xray -Launcher $LauncherPath

$exitIp = Test-Tunnel -ProxyUrl $ProxyUrl

Say 'Summary'
Note "install dir : $InstallDir"
Note "config      : $ConfigPath"
Note "local proxy : $ProxyUrl  (HTTP and SOCKS5)"
if ($NoClaude) {
    Note 'claude code : untouched - add this to .claude\settings.json manually:'
    Note ('              "env": { "HTTPS_PROXY": "' + $ProxyUrl + '", "HTTP_PROXY": "' + $ProxyUrl + '", "NO_PROXY": "' + $NoProxyList + '" }')
} else {
    Note "claude code : $ClaudePath"
}

Write-Host ''
if ($exitIp) {
    Write-Host "Tunnel works. Exit IP: $exitIp" -ForegroundColor Green
} else {
    Warn "the proxy did not answer. Check $ConfigPath and the logs, then re-run:" 
    Warn ('  cd "' + $InstallDir + '"; .\xray.exe run -c config.json')
}

Write-Host ''
Note 'Useful commands:'
Note ('  stop     : Get-Process xray -ErrorAction SilentlyContinue | Stop-Process')
Note ('  start    : wscript.exe "' + $LauncherPath + '"')
Note ('  test     : (Invoke-WebRequest https://api.ipify.org -Proxy ' + $ProxyUrl + ').Content')
Note ('  remove   : .\setup-windows.ps1 -Uninstall')
