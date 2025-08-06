# Automated PowerShell script to install libimobiledevice via MSYS2, MVT spyware checker, and add iPhone log functions to $PROFILE on Windows using winget.

# Ensure winget is available
if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    Write-Host "winget not found. Ensure Windows App Installer is installed."
    exit 1
}

# Better check for functional Python
$pythonInstalled = $false
try {
    $pythonOutput = & python --version 2>&1
    if ($pythonOutput -match "Python\s+3\.\d+") {
        $pythonInstalled = $true
    }
} catch {}

if (-not $pythonInstalled) {
    Write-Host "Functional Python not detected. Installing Python via winget..."
    winget install -e --id Python.Python.3.11 --scope user --accept-package-agreements --accept-source-agreements
    Write-Host "Python installed. Please restart PowerShell for path updates, then rerun this script."
    exit 0
}

# Refresh environment path after potential install (though restart is better)
$env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")

# Install pip if not present
$pipInstalled = $false
try {
    $pipOutput = & pip --version 2>&1
    if ($pipOutput -match "pip\s+\d+\.\d+") {
        $pipInstalled = $true
    }
} catch {}

if (-not $pipInstalled) {
    Write-Host "pip not found. Ensuring pip..."
    python -m ensurepip
    python -m pip install --upgrade pip
}

# Install MVT via pip
Write-Host "Installing MVT..."
python -m pip install mvt

# Install MSYS2 if not already installed
$msysPath = "C:\msys64"
if (-not (Test-Path $msysPath)) {
    Write-Host "Installing MSYS2 via winget..."
    winget install -e --id MSYS2.MSYS2 --accept-package-agreements --accept-source-agreements
}

# Update MSYS2 and install libimobiledevice
Write-Host "Updating MSYS2 and installing libimobiledevice..."
& "$msysPath\usr\bin\bash.exe" -lc "pacman -Syu --noconfirm"
& "$msysPath\usr\bin\bash.exe" -lc "pacman -S --noconfirm mingw-w64-x86_64-libimobiledevice mingw-w64-x86_64-usbmuxd mingw-w64-x86_64-libusb mingw-w64-x86_64-libplist mingw-w64-x86_64-openssl"

# Add MSYS2 mingw64 bin to PATH if not already
$binPath = "$msysPath\mingw64\bin"
$currentPath = [System.Environment]::GetEnvironmentVariable("Path", "User")
if ($currentPath -notmatch [regex]::Escape($binPath)) {
    $newPath = "$currentPath;$binPath"
    [System.Environment]::SetEnvironmentVariable("Path", $newPath, "User")
    $env:Path = $newPath
    Write-Host "Added $binPath to user PATH. Restart PowerShell if commands are not found."
}

# Verify installations
$libInstalled = Get-Command idevicesyslog -ErrorAction SilentlyContinue
$mvtInstalled = Get-Command mvt-ios -ErrorAction SilentlyContinue
if (-not $libInstalled -or -not $mvtInstalled) {
    Write-Host "Installation failed. Check dependencies. May need to restart PowerShell or verify MSYS2 setup."
    exit 1
}

# Define functions as a string block
$functions = @'

function iLive {
    param (
        [switch]$v
    )
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $logDir = "$HOME\GNO-DATA\iPhone\LiveLogs\$timestamp"
    New-Item -ItemType Directory -Force -Path $logDir | Out-Null
    $logFile = "$logDir\iphone_syslog_$timestamp.log"

    if (-not (idevice_id -l)) {
        Write-Host "No iPhone detected. Connect via USB and ensure it's trusted."
        return 1
    }

    if ($v) {
        Write-Host "Starting verbose live debugging. Press Ctrl+C to stop."
        idevicesyslog | Tee-Object -FilePath $logFile
    } else {
        Write-Host "Starting live logging. Logs saved to $logFile. Press Ctrl+C to stop."
        idevicesyslog > $logFile
    }
}

function iCopy {
    if (-not (idevice_id -l)) {
        Write-Host "No iPhone detected. Connect via USB and ensure it's trusted."
        return 1
    }
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $logDir = "$HOME\GNO-DATA\iPhone\ExtractedLogs\$timestamp"
    New-Item -ItemType Directory -Force -Path $logDir | Out-Null

    Write-Host "Collecting syslog (5s sample)..."
    $proc = Start-Process -FilePath "idevicesyslog" -RedirectStandardOutput "$logDir\iphone_syslog.log" -NoNewWindow -PassThru
    Start-Sleep -Seconds 5
    Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue

    Write-Host "Collecting device info..."
    ideviceinfo > "$logDir\iphone_device_info.txt"

    Write-Host "Collecting diagnostics..."
    idevicediagnostics diagnostics > "$logDir\iphone_diagnostics.txt"

    Write-Host "Collecting crash reports..."
    $crashDir = "$logDir\crash_reports"
    New-Item -ItemType Directory -Force -Path $crashDir | Out-Null
    idevicecrashreport -e $crashDir

    Write-Host "Logs copied to $logDir"
}

function iCheckSpyware {
    param (
        [string]$backupDirParam = $null
    )
    if (-not (idevice_id -l)) {
        Write-Host "No iPhone detected. Connect via USB and ensure it's trusted."
        return 1
    }

    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $backupDir = if ($backupDirParam) { $backupDirParam } else { "$HOME\GNO-DATA\iPhone\Backups\$timestamp" }
    New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
    $outputDir = "$backupDir\mvt_output"
    New-Item -ItemType Directory -Force -Path $outputDir | Out-Null

    # Download MVT IOCs
    $iocsUrl = "https://raw.githubusercontent.com/mvt-project/mvt/main/indicators/all.json"
    $iocsPath = "$backupDir\iocs.json"
    Invoke-WebRequest -Uri $iocsUrl -OutFile $iocsPath

    Write-Host "Creating encrypted backup (you will be prompted for password)..."
    idevicebackup2 backup --full --encryption on $backupDir
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Backup failed."
        return 1
    }

    Write-Host "Checking for spyware indicators..."
    mvt-ios check-backup --output $outputDir $backupDir --iocs $iocsPath

    Write-Host "Spyware check results in $outputDir"
}

'@

# Append functions to $PROFILE if not already present
$profilePath = $PROFILE
if (-not (Test-Path $profilePath)) {
    New-Item -ItemType File -Path $profilePath -Force | Out-Null
}

$profileContent = Get-Content $profilePath -Raw -ErrorAction SilentlyContinue
if (-not ($profileContent -match "function iLive")) {
    Add-Content -Path $profilePath -Value $functions
    Write-Host "Functions added to $PROFILE."
} else {
    Write-Host "Functions already present in $PROFILE. Skipping append."
}

# To load immediately, dot-source the profile
. $PROFILE

Write-Host "Setup complete. Connect iPhone via USB, trust the computer. Functions ready: iLive [-v], iCopy, iCheckSpyware [backup_dir]"
Write-Host "Note: MSYS2 installed for libimobiledevice; binaries in $msysPath\mingw64\bin added to PATH. Dependencies like libusb, libplist, openssl installed."
