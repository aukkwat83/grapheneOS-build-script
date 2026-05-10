<#
    pixelflash.ps1
    GrapheneOS factory-image flasher (Windows 11) for ROMs built on Ubuntu.
    - Self-elevates (UAC)
    - Installs chocolatey, putty (plink/pscp), gnupg, adb (with fastboot)
    - Pulls /home/<user>/grapheneos-*.tar.gpg + README* from the build server
    - Decrypts the .tar.gpg, extracts the factory image to Desktop
    - Detects the Pixel in fastboot, unlocks bootloader, runs flash-all.bat
      (full wipe), then assists re-locking the bootloader.
#>

[CmdletBinding()]
param(
    [switch]$SkipFlash,   # do everything except touching the phone
    [switch]$DepsOnly,    # install tools only
    [switch]$Elevated     # internal: set after self-elevation
)

# =================== EDIT HERE ===================
$SERVER_OS   = 'Ubuntu24.04LTS'
$SERVER_HOST = '10.211.55.14'
$SERVER_USER = 'aukkwat'
$SERVER_PASS = 'bigmaster'
# =================================================

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

$DesktopPath = [Environment]::GetFolderPath('Desktop')
$WorkDir     = Join-Path $DesktopPath 'GrapheneOS-Flash'
$DownloadDir = Join-Path $WorkDir   'downloads'
$ExtractDir  = Join-Path $WorkDir   'extracted'
$LogFile     = Join-Path $WorkDir   'pixelflash.log'

function W-Step([string]$m){ Write-Host "`n[STEP] $m" -ForegroundColor Cyan }
function W-Info([string]$m){ Write-Host "[INFO] $m" -ForegroundColor Gray }
function W-Ok  ([string]$m){ Write-Host "[ OK ] $m" -ForegroundColor Green }
function W-Warn([string]$m){ Write-Host "[WARN] $m" -ForegroundColor Yellow }
function W-Err ([string]$m){ Write-Host "[FAIL] $m" -ForegroundColor Red }

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]$id).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Refresh-Path {
    $machine = [Environment]::GetEnvironmentVariable('Path','Machine')
    $user    = [Environment]::GetEnvironmentVariable('Path','User')
    $env:Path = "$machine;$user"
    $extras = @(
        'C:\ProgramData\chocolatey\bin',
        'C:\Program Files\PuTTY',
        'C:\Program Files (x86)\PuTTY',
        'C:\Program Files\GnuPG\bin',
        'C:\Program Files (x86)\GnuPG\bin',
        'C:\ProgramData\chocolatey\lib\adb\tools',
        'C:\Program Files (x86)\Android\android-sdk\platform-tools'
    )
    foreach($e in $extras){
        if((Test-Path $e) -and ($env:Path -notlike "*$e*")){ $env:Path += ";$e" }
    }
}

function Run-Native([string]$exe, [string[]]$argList){
    $so = [IO.Path]::GetTempFileName()
    $se = [IO.Path]::GetTempFileName()
    $p  = Start-Process -FilePath $exe -ArgumentList $argList -NoNewWindow -Wait -PassThru `
                        -RedirectStandardOutput $so -RedirectStandardError $se
    $o  = ''; $e = ''
    if(Test-Path $so){ $o = Get-Content $so -Raw -ErrorAction SilentlyContinue }
    if(Test-Path $se){ $e = Get-Content $se -Raw -ErrorAction SilentlyContinue }
    Remove-Item $so, $se -Force -ErrorAction SilentlyContinue
    [pscustomobject]@{ ExitCode = $p.ExitCode; StdOut = $o; StdErr = $e }
}

function Ensure-Choco {
    if(Get-Command choco -ErrorAction SilentlyContinue){ W-Ok 'Chocolatey present'; return }
    W-Info 'Installing Chocolatey...'
    Set-ExecutionPolicy Bypass -Scope Process -Force
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072
    Invoke-Expression ((New-Object Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
    Refresh-Path
    if(-not (Get-Command choco -ErrorAction SilentlyContinue)){ throw 'Chocolatey install failed' }
    W-Ok 'Chocolatey installed'
}

function Ensure-Pkg([string]$pkg, [string]$probe){
    if(Get-Command $probe -ErrorAction SilentlyContinue){ W-Ok "$probe present"; return }
    W-Info "choco install $pkg"
    & choco install $pkg -y --no-progress --limit-output
    # 0 = ok, 1641/3010 = success but reboot required
    if($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 1641 -and $LASTEXITCODE -ne 3010){
        throw "choco install $pkg failed (exit $LASTEXITCODE)"
    }
    Refresh-Path
    if(-not (Get-Command $probe -ErrorAction SilentlyContinue)){
        throw "$probe not found on PATH after installing $pkg"
    }
    W-Ok "$probe ready"
}

function Install-Toolchain {
    W-Step 'Toolchain'
    Ensure-Choco
    Ensure-Pkg 'putty' 'plink'
    Ensure-Pkg 'putty' 'pscp'
    Ensure-Pkg 'gnupg' 'gpg'
    Ensure-Pkg 'adb'   'adb'
    Ensure-Pkg 'adb'   'fastboot'
    if(-not (Get-Command tar -ErrorAction SilentlyContinue)){ throw 'tar missing (built into Win10+)' }
    W-Ok 'Toolchain ready'
}

function Cache-SshHostKey {
    W-Step "Cache SSH host key for $SERVER_HOST"
    # Pre-accept fingerprint into PuTTY's registry so -batch works
    cmd.exe /c "echo y | plink -ssh -pw `"$SERVER_PASS`" $SERVER_USER@$SERVER_HOST exit > NUL 2>&1"
    W-Ok 'Host key cached'
}

function Plink-Exec([string]$remoteCmd){
    $r = Run-Native 'plink' @('-ssh','-batch','-pw',$SERVER_PASS,"$SERVER_USER@$SERVER_HOST",$remoteCmd)
    if($r.ExitCode -ne 0){
        throw "plink failed (exit $($r.ExitCode)): $($r.StdErr)$($r.StdOut)"
    }
    return $r.StdOut
}

function Pscp-Get([string]$remote, [string]$local){
    $r = Run-Native 'pscp' @('-batch','-pw',$SERVER_PASS,"${SERVER_USER}@${SERVER_HOST}:$remote",$local)
    if($r.ExitCode -ne 0){
        throw "pscp failed (exit $($r.ExitCode)): $($r.StdErr)$($r.StdOut)"
    }
}

function Sync-FromServer {
    W-Step "Sync from $SERVER_USER@$SERVER_HOST"
    # Use `find` so a missing pattern is not fatal (ls returns 2 when one glob has no matches)
    $listing = Plink-Exec "find /home/$SERVER_USER -maxdepth 1 -type f \( -name 'grapheneos-*.tar.gpg' -o -iname 'README*' \) 2>/dev/null; true"
    $files = $listing -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    $gpgFiles    = @($files | Where-Object { $_ -like '*grapheneos-*.tar.gpg' })
    $readmeFiles = @($files | Where-Object { (Split-Path $_ -Leaf) -match '^(?i)README' })
    if(-not $gpgFiles){ throw "No grapheneos-*.tar.gpg under /home/$SERVER_USER" }
    if(-not $readmeFiles){ W-Warn "No README* on server (will continue without it)" }
    W-Info ("Found: " + ($files -join ', '))

    New-Item -ItemType Directory -Path $DownloadDir -Force | Out-Null
    foreach($f in $files){
        $name  = Split-Path $f -Leaf
        $local = Join-Path $DownloadDir $name
        if(Test-Path $local){
            $remoteSize = [int64]((Plink-Exec "stat -c %s `"$f`"").Trim())
            $localSize  = (Get-Item $local).Length
            if($remoteSize -eq $localSize){
                W-Info "Skip identical $name ($localSize bytes)"
                continue
            }
        }
        W-Info "Download $name"
        Pscp-Get $f $local
        W-Ok "Got $name ($((Get-Item $local).Length) bytes)"
    }
}

function Show-Readme {
    $r = Get-ChildItem -Path $DownloadDir -Filter 'README*' -ErrorAction SilentlyContinue | Select-Object -First 1
    if(-not $r){ W-Warn 'README not found'; return }
    Write-Host ""
    Write-Host "----- $($r.Name) -----" -ForegroundColor Magenta
    Get-Content $r.FullName | ForEach-Object { Write-Host "  $_" }
    Write-Host "----- end README -----" -ForegroundColor Magenta
    Write-Host ""
}

function Decrypt-Extract {
    W-Step 'Decrypt + extract'
    $stamp = Join-Path $ExtractDir '.extracted.ok'
    if(Test-Path $stamp){
        W-Ok 'ROM already extracted (delete .extracted.ok in extracted/ to force redo)'
        return
    }
    $gpg = Get-ChildItem -Path $DownloadDir -Filter 'grapheneos-*.tar.gpg' | Select-Object -First 1
    if(-not $gpg){ throw 'No grapheneos-*.tar.gpg found locally' }
    Show-Readme

    $sec  = Read-Host -AsSecureString -Prompt "GPG passphrase for $($gpg.Name)"
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    $pp   = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)

    $tar = Join-Path $DownloadDir ($gpg.BaseName)   # grapheneos-foo.tar.gpg -> grapheneos-foo.tar
    if(Test-Path $tar){ Remove-Item $tar -Force }

    $pp | & gpg --batch --yes --pinentry-mode loopback --passphrase-fd 0 `
                --output $tar --decrypt $gpg.FullName
    if($LASTEXITCODE -ne 0){ throw 'gpg decrypt failed (wrong passphrase?)' }
    W-Ok "Decrypted -> $tar"

    if(Test-Path $ExtractDir){ Remove-Item $ExtractDir -Recurse -Force }
    New-Item -ItemType Directory -Path $ExtractDir -Force | Out-Null
    & tar -xf $tar -C $ExtractDir
    if($LASTEXITCODE -ne 0){ throw 'tar -xf failed' }
    W-Ok "Extracted -> $ExtractDir"
    Get-ChildItem $ExtractDir | ForEach-Object { W-Info "  $($_.Name)" }
    New-Item -Path $stamp -ItemType File -Force | Out-Null
}

function Find-FlashAll {
    $bat = Get-ChildItem -Path $ExtractDir -Filter 'flash-all.bat' -Recurse -ErrorAction SilentlyContinue |
           Select-Object -First 1
    if($bat){ return $bat }

    # GrapheneOS-built tarballs ship a nested factory zip, e.g.
    #   releases/<date>/release-<device>-<date>/<device>-factory-<date>.zip
    # Extract it to expose flash-all.bat
    $zip = Get-ChildItem -Path $ExtractDir -Filter '*-factory-*.zip' -Recurse -ErrorAction SilentlyContinue |
           Select-Object -First 1
    if(-not $zip){ throw 'flash-all.bat / *-factory-*.zip not found in extracted ROM' }

    $factoryDir = Join-Path $zip.DirectoryName $zip.BaseName
    if(-not (Test-Path (Join-Path $factoryDir 'flash-all.bat'))){
        W-Info "Extracting factory zip: $($zip.Name)"
        New-Item -ItemType Directory -Path $factoryDir -Force | Out-Null
        Push-Location $factoryDir
        try {
            & tar -xf $zip.FullName
            if($LASTEXITCODE -ne 0){ throw "tar -xf $($zip.Name) failed (exit $LASTEXITCODE)" }
        } finally { Pop-Location }
    }
    # Some factory zips extract into a sub-folder (e.g. shiba-2026051001/...)
    $bat = Get-ChildItem -Path $factoryDir -Filter 'flash-all.bat' -Recurse -ErrorAction SilentlyContinue |
           Select-Object -First 1
    if(-not $bat){ throw "flash-all.bat not found after extracting $($zip.Name)" }
    return $bat
}

function Wait-Fastboot {
    W-Info 'Waiting for fastboot device... (Vol-Down + Power, OR plug in with USB debugging on)'
    $rebootedAt = $null
    while($true){
        $r = Run-Native 'fastboot' @('devices')
        if($r.StdOut -match '\bfastboot\b'){
            W-Ok ("fastboot: " + ($r.StdOut.Trim() -replace '\s+',' '))
            return
        }
        # If an authorized ADB device shows up later, auto-reboot it into bootloader.
        # Re-arm every 30s in case the first reboot got stuck.
        $a = Run-Native 'adb' @('devices')
        if($a.StdOut -match "(?m)^\S+\s+device\b"){
            $now = Get-Date
            if(-not $rebootedAt -or ($now - $rebootedAt).TotalSeconds -gt 30){
                W-Info 'adb device detected -> issuing `adb reboot bootloader`'
                Run-Native 'adb' @('reboot','bootloader') | Out-Null
                $rebootedAt = $now
            }
        } elseif($a.StdOut -match 'unauthorized'){
            W-Warn 'adb shows "unauthorized" - tap "Allow USB debugging" on the phone.'
            Start-Sleep -Seconds 3
        }
        Start-Sleep -Seconds 2
    }
}

function Ensure-Fastboot {
    $r = Run-Native 'fastboot' @('devices')
    if($r.StdOut -match '\bfastboot\b'){ W-Ok 'Already in fastboot'; return }
    $a = Run-Native 'adb' @('devices')
    if($a.StdOut -match "(?m)^\S+\s+device\b"){
        W-Info 'Found adb device — rebooting to bootloader...'
        Run-Native 'adb' @('reboot','bootloader') | Out-Null
        Start-Sleep -Seconds 5
    }
    Wait-Fastboot
}

function Show-DeviceTutorial {
@'

================ READY THE PIXEL ================
On the Pixel (do this BEFORE the script can touch it):
  1) Settings -> About phone -> tap "Build number" 7 times (enable Developer options)
  2) Settings -> System -> Developer options ->
       - enable "OEM unlocking"
       - enable "USB debugging"
  3) Connect the Pixel to PC with a known-good USB-C data cable.
  4) Tap "Allow USB debugging" on the device when prompted.

The script will then auto-issue `adb reboot bootloader`.
If the phone is dead/never set up, manually do:
  - Power off
  - Hold Volume Down + Power until the bootloader screen
  - Connect USB
=================================================

'@ | Write-Host -ForegroundColor Yellow
}

function Confirm-Wipe {
    Write-Host @'

WARNING: The next steps will UNLOCK THE BOOTLOADER and FLASH the device.
ALL DATA on the connected phone will be ERASED.

'@ -ForegroundColor Red
    $a = Read-Host 'Type "WIPE" to continue'
    if($a -ne 'WIPE'){ throw 'User aborted before flash' }
}

function Unlock-Bootloader {
    W-Step 'Unlock bootloader'
    $r = Run-Native 'fastboot' @('getvar','unlocked')
    if(($r.StdOut + $r.StdErr) -match 'unlocked:\s*yes'){
        W-Ok 'Bootloader already unlocked'
        return
    }
    Write-Host @'
Sending: fastboot flashing unlock
On the phone: Volume Up to highlight "Unlock the bootloader", Power to confirm.
'@ -ForegroundColor Yellow
    Run-Native 'fastboot' @('flashing','unlock') | Out-Null
    W-Info 'Waiting ~12s for the device to come back to fastboot...'
    Start-Sleep -Seconds 12
    Wait-Fastboot
    W-Ok 'Bootloader unlocked'
}

function Run-FlashAll {
    W-Step 'flash-all.bat (full wipe install)'
    $bat = Find-FlashAll
    Push-Location $bat.DirectoryName
    try {
        & cmd.exe /c "`"$($bat.FullName)`""
        if($LASTEXITCODE -ne 0){ throw "flash-all.bat exit $LASTEXITCODE" }
    } finally { Pop-Location }
    W-Ok 'flash-all.bat finished — device rebooting into GrapheneOS'
}

function Lock-Bootloader {
    W-Step 'Re-lock bootloader (Verified Boot)'
    Write-Host @'

To re-lock you MUST:
  1) Boot into GrapheneOS, finish enough setup to reach Settings.
  2) Settings -> About phone -> tap Build number 7x
  3) Settings -> System -> Developer options -> enable "OEM unlocking"
  4) Power off, then Vol-Down + Power back into the bootloader.
Press Enter here when the device is at the bootloader screen,
or type "skip" to skip locking (you can lock later manually).

'@ -ForegroundColor Yellow
    $a = Read-Host 'Enter to continue, or "skip"'
    if($a -eq 'skip'){ W-Warn 'Skipping lock — remember to lock later for Verified Boot.'; return }
    Wait-Fastboot
    Write-Host 'Confirm "Lock the bootloader" on the device with Volume + Power.' -ForegroundColor Yellow
    $r = Run-Native 'fastboot' @('flashing','lock')
    if($r.ExitCode -ne 0){
        W-Warn "flashing lock returned $($r.ExitCode): $($r.StdErr)$($r.StdOut)"
        W-Warn 'Most common cause: OEM unlocking toggle was not re-enabled. Re-enable and retry.'
    } else {
        W-Ok 'Lock command sent — device will wipe again and reboot into the locked OS.'
    }
}

# ====================== ENTRY ======================
if(-not (Test-Admin) -and -not $Elevated){
    Write-Host 'Re-launching elevated (UAC prompt incoming)...' -ForegroundColor Yellow
    $relaunch = @('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$PSCommandPath`"",'-Elevated')
    if($SkipFlash){ $relaunch += '-SkipFlash' }
    if($DepsOnly){  $relaunch += '-DepsOnly'  }
    Start-Process -FilePath powershell.exe -Verb RunAs -ArgumentList $relaunch
    exit
}

New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null
try { Start-Transcript -Path $LogFile -Append | Out-Null } catch {}

try {
    Write-Host @"

============================================================
   GrapheneOS Flash Automation - Windows Edition
============================================================
Server : $SERVER_USER@$SERVER_HOST  ($SERVER_OS)
Workdir: $WorkDir
Logfile: $LogFile
============================================================
"@ -ForegroundColor Cyan

    Refresh-Path
    Install-Toolchain
    Refresh-Path
    if($DepsOnly){ W-Ok 'DepsOnly: tools installed, exiting.'; return }

    Cache-SshHostKey
    Sync-FromServer
    Decrypt-Extract

    if($SkipFlash){
        W-Warn '-SkipFlash specified: stopping before flash. ROM is at:'
        W-Info $ExtractDir
        return
    }

    Show-DeviceTutorial
    Ensure-Fastboot
    Confirm-Wipe
    Unlock-Bootloader
    Run-FlashAll
    Lock-Bootloader

    Write-Host "`n[DONE] GrapheneOS installation complete." -ForegroundColor Green
} catch {
    W-Err $_.Exception.Message
    if($_.ScriptStackTrace){ W-Err $_.ScriptStackTrace }
} finally {
    try { Stop-Transcript | Out-Null } catch {}
    Read-Host 'Press Enter to close' | Out-Null
}
