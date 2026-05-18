<#
.SYNOPSIS
  UAC Silent Launcher — Create desktop shortcuts that bypass UAC popups

.DESCRIPTION
  Uses Windows Task Scheduler to create whitelist-style silent privilege elevation.
  Does NOT modify system security settings. Only affects programs you choose.

.PARAMETER TargetPath
  Full path to target .exe (CLI mode)

.PARAMETER ShortcutName
  Shortcut name, auto-generated if not specified

.PARAMETER Remove
  Remove a silent task and its shortcut (CLI mode, requires -RemoveTaskName)

.PARAMETER RemoveTaskName
  Name of the task to remove

.PARAMETER List
  List all existing silent tasks

.EXAMPLE
  .\UACSilentLauncher.ps1                          # Launch GUI
  .\UACSilentLauncher.ps1 -TargetPath "C:\app.exe" # CLI: create
  .\UACSilentLauncher.ps1 -List                     # CLI: list all
  .\UACSilentLauncher.ps1 -Remove -RemoveTaskName "UACSilent_App"  # CLI: remove
#>

param(
    [string]$TargetPath,
    [string]$ShortcutName,
    [switch]$Remove,
    [string]$RemoveTaskName,
    [switch]$List
)

$ErrorActionPreference = "Stop"

# ============================================================
# Core Functions
# ============================================================

function Get-TaskNameFromPath {
    param([string]$ExePath)
    $base = [System.IO.Path]::GetFileNameWithoutExtension($ExePath)
    return "UACSilent_$base"
}

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-ExistingSilentTasks {
    $tasks = schtasks /query /fo CSV /v 2>$null | ConvertFrom-Csv 2>$null
    $result = @()
    if ($tasks) {
        foreach ($t in $tasks) {
            if ($t.TaskName -like 'UACSilent_*') {
                $result += [PSCustomObject]@{
                    TaskName = $t.TaskName
                    AppName  = $t.TaskName -replace '^UACSilent_', ''
                    Status   = $t.Status
                }
            }
        }
    }
    return $result
}

function Get-ExeIcon {
    param([string]$ExePath)
    try {
        Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue
        $icon = [System.Drawing.Icon]::ExtractAssociatedIcon($ExePath)
        if ($icon) {
            $icoPath = "$env:TEMP\" + [System.IO.Path]::GetFileNameWithoutExtension($ExePath) + ".ico"
            $stream = [System.IO.File]::OpenWrite($icoPath)
            $icon.Save($stream)
            $stream.Close()
            $icon.Dispose()
            return $icoPath
        }
    } catch {}
    return $null
}

function New-SilentTask {
    param([string]$ExePath, [string]$TaskName)

    if (-not (Test-Path $ExePath)) {
        throw "File not found: $ExePath"
    }

    $user = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    schtasks /delete /tn "$TaskName" /f 2>$null

    $result = schtasks /create `
        /tn "$TaskName" `
        /tr """$ExePath""" `
        /sc ONCE `
        /st 00:00 `
        /ru "$user" `
        /rl HIGHEST `
        /f 2>&1

    if ($LASTEXITCODE -ne 0) {
        throw "Failed to create task: $result"
    }
}

function Remove-SilentTask {
    param([string]$TaskName)

    schtasks /query /tn "$TaskName" 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Task not found: $TaskName"
    }

    schtasks /delete /tn "$TaskName" /f 2>&1 | Out-Null

    $desktop = [Environment]::GetFolderPath('Desktop')
    $lnkPath = Join-Path $desktop "$TaskName.lnk"
    if (Test-Path $lnkPath) {
        Remove-Item $lnkPath -Force
    }
}

function New-LauncherShortcut {
    param([string]$ExePath, [string]$TaskName, [string]$ShortcutName)

    $desktop = [Environment]::GetFolderPath('Desktop')
    $lnkPath = Join-Path $desktop "$ShortcutName.lnk"

    $ws = New-Object -ComObject WScript.Shell
    $sc = $ws.CreateShortcut($lnkPath)
    $sc.TargetPath = 'schtasks.exe'
    $sc.Arguments = "/run /tn ""$TaskName"""
    $sc.WorkingDirectory = Split-Path -Parent $ExePath
    $sc.WindowStyle = 7

    $icoPath = Get-ExeIcon -ExePath $ExePath
    if ($icoPath -and (Test-Path $icoPath)) {
        $sc.IconLocation = $icoPath
    } else {
        $sc.IconLocation = "$ExePath,0"
    }
    $sc.Save()
    return $lnkPath
}

# ============================================================
# GUI
# ============================================================

function Show-GUI {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'UAC Silent Launcher v1.0'
    $form.Size = New-Object System.Drawing.Size(620, 500)
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = 'FixedSingle'
    $form.MaximizeBox = $false
    $form.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)

    # Title label
    $lblTitle = New-Object System.Windows.Forms.Label
    $lblTitle.Text = 'Drag an .exe here, click Create, done. No more UAC popup.'
    $lblTitle.Location = New-Object System.Drawing.Point(16, 12)
    $lblTitle.Size = New-Object System.Drawing.Size(580, 24)
    $lblTitle.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10, [System.Drawing.FontStyle]::Bold)
    $form.Controls.Add($lblTitle)

    # Target label
    $lblTarget = New-Object System.Windows.Forms.Label
    $lblTarget.Text = 'Target Program (.exe):'
    $lblTarget.Location = New-Object System.Drawing.Point(16, 50)
    $lblTarget.Size = New-Object System.Drawing.Size(300, 20)
    $form.Controls.Add($lblTarget)

    # Target text box
    $txtTarget = New-Object System.Windows.Forms.TextBox
    $txtTarget.Location = New-Object System.Drawing.Point(16, 72)
    $txtTarget.Size = New-Object System.Drawing.Size(450, 23)
    $txtTarget.AllowDrop = $true
    $form.Controls.Add($txtTarget)

    $txtTarget.Add_DragEnter({
        if ($_.Data.GetDataPresent([Windows.Forms.DataFormats]::FileDrop)) {
            $_.Effect = [Windows.Forms.DragDropEffects]::Copy
        }
    })
    $txtTarget.Add_DragDrop({
        $files = $_.Data.GetData([Windows.Forms.DataFormats]::FileDrop)
        if ($files -and $files.Count -gt 0) {
            $txtTarget.Text = $files[0]
        }
    })

    # Browse button
    $btnBrowse = New-Object System.Windows.Forms.Button
    $btnBrowse.Text = 'Browse...'
    $btnBrowse.Location = New-Object System.Drawing.Point(476, 70)
    $btnBrowse.Size = New-Object System.Drawing.Size(120, 27)
    $btnBrowse.Add_Click({
        $dlg = New-Object System.Windows.Forms.OpenFileDialog
        $dlg.Filter = 'Executable files (*.exe)|*.exe|All files (*.*)|*.*'
        $dlg.Title = 'Select target program'
        if ($dlg.ShowDialog() -eq 'OK') {
            $txtTarget.Text = $dlg.FileName
            $name = [System.IO.Path]::GetFileNameWithoutExtension($dlg.FileName)
            $txtShortName.Text = "$name (Silent Launch)"
        }
    })
    $form.Controls.Add($btnBrowse)

    # Shortcut name label
    $lblShort = New-Object System.Windows.Forms.Label
    $lblShort.Text = 'Shortcut Name:'
    $lblShort.Location = New-Object System.Drawing.Point(16, 108)
    $lblShort.Size = New-Object System.Drawing.Size(300, 20)
    $form.Controls.Add($lblShort)

    # Shortcut name text box
    $txtShortName = New-Object System.Windows.Forms.TextBox
    $txtShortName.Location = New-Object System.Drawing.Point(16, 130)
    $txtShortName.Size = New-Object System.Drawing.Size(450, 23)
    $form.Controls.Add($txtShortName)

    $txtTarget.Add_TextChanged({
        if ($txtTarget.Text -and (Test-Path $txtTarget.Text)) {
            $ext = [System.IO.Path]::GetExtension($txtTarget.Text)
            if ($ext -eq '.exe') {
                $name = [System.IO.Path]::GetFileNameWithoutExtension($txtTarget.Text)
                $txtShortName.Text = "$name (Silent Launch)"
            }
        }
    })

    # Create button
    $btnCreate = New-Object System.Windows.Forms.Button
    $btnCreate.Text = 'Create Silent Shortcut'
    $btnCreate.Location = New-Object System.Drawing.Point(16, 175)
    $btnCreate.Size = New-Object System.Drawing.Size(200, 36)
    $btnCreate.BackColor = [System.Drawing.Color]::FromArgb(37, 99, 235)
    $btnCreate.ForeColor = [System.Drawing.Color]::White
    $btnCreate.FlatStyle = 'Flat'
    $btnCreate.FlatAppearance.BorderSize = 0
    $form.Controls.Add($btnCreate)

    # Remove button
    $btnRemove = New-Object System.Windows.Forms.Button
    $btnRemove.Text = 'Delete Selected Task'
    $btnRemove.Location = New-Object System.Drawing.Point(226, 175)
    $btnRemove.Size = New-Object System.Drawing.Size(200, 36)
    $btnRemove.BackColor = [System.Drawing.Color]::FromArgb(239, 68, 68)
    $btnRemove.ForeColor = [System.Drawing.Color]::White
    $btnRemove.FlatStyle = 'Flat'
    $btnRemove.FlatAppearance.BorderSize = 0
    $form.Controls.Add($btnRemove)

    # Refresh button
    $btnRefresh = New-Object System.Windows.Forms.Button
    $btnRefresh.Text = 'Refresh'
    $btnRefresh.Location = New-Object System.Drawing.Point(436, 175)
    $btnRefresh.Size = New-Object System.Drawing.Size(160, 36)
    $form.Controls.Add($btnRefresh)

    # Task list label
    $lblList = New-Object System.Windows.Forms.Label
    $lblList.Text = 'Created Silent Tasks:'
    $lblList.Location = New-Object System.Drawing.Point(16, 225)
    $lblList.Size = New-Object System.Drawing.Size(300, 20)
    $form.Controls.Add($lblList)

    # Task list view
    $listTasks = New-Object System.Windows.Forms.ListView
    $listTasks.Location = New-Object System.Drawing.Point(16, 248)
    $listTasks.Size = New-Object System.Drawing.Size(580, 120)
    $listTasks.View = 'Details'
    $listTasks.FullRowSelect = $true
    $listTasks.GridLines = $true
    [void]$listTasks.Columns.Add('Task Name', 220)
    [void]$listTasks.Columns.Add('App Name', 200)
    [void]$listTasks.Columns.Add('Status', 140)
    $form.Controls.Add($listTasks)

    # Log label
    $lblLog = New-Object System.Windows.Forms.Label
    $lblLog.Text = 'Log:'
    $lblLog.Location = New-Object System.Drawing.Point(16, 380)
    $lblLog.Size = New-Object System.Drawing.Size(100, 18)
    $form.Controls.Add($lblLog)

    # Log text box
    $txtLog = New-Object System.Windows.Forms.TextBox
    $txtLog.Location = New-Object System.Drawing.Point(16, 400)
    $txtLog.Size = New-Object System.Drawing.Size(580, 58)
    $txtLog.Multiline = $true
    $txtLog.ScrollBars = 'Vertical'
    $txtLog.ReadOnly = $true
    $txtLog.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
    $txtLog.ForeColor = [System.Drawing.Color]::FromArgb(0, 200, 0)
    $txtLog.Font = New-Object System.Drawing.Font('Consolas', 8)
    $form.Controls.Add($txtLog)

    function Local:Refresh-TaskList {
        $listTasks.Items.Clear()
        $tasks = Get-ExistingSilentTasks
        foreach ($t in $tasks) {
            $item = New-Object System.Windows.Forms.ListViewItem($t.TaskName)
            [void]$item.SubItems.Add($t.AppName)
            [void]$item.SubItems.Add($t.Status)
            $listTasks.Items.Add($item)
        }
        $txtLog.AppendText("[OK] Task list refreshed.`r`n")
    }

    $btnRefresh.Add_Click({ Local:Refresh-TaskList })

    # Create click handler
    $btnCreate.Add_Click({
        $exe = $txtTarget.Text.Trim()
        $shortName = $txtShortName.Text.Trim()

        if (-not $exe) {
            [System.Windows.Forms.MessageBox]::Show(
                'Please select a target .exe file.', 'UAC Silent Launcher', 'OK', 'Warning')
            return
        }
        if (-not (Test-Path $exe)) {
            [System.Windows.Forms.MessageBox]::Show(
                "File not found: $exe", 'UAC Silent Launcher', 'OK', 'Error')
            return
        }
        if ([System.IO.Path]::GetExtension($exe) -ne '.exe') {
            [System.Windows.Forms.MessageBox]::Show(
                'Only .exe files are supported.', 'UAC Silent Launcher', 'OK', 'Error')
            return
        }
        if (-not $shortName) {
            $shortName = [System.IO.Path]::GetFileNameWithoutExtension($exe) + ' (Silent Launch)'
        }

        try {
            if (-not (Test-IsAdmin)) {
                $txtLog.AppendText("[..] Requesting admin privileges...`r`n")
                $form.TopMost = $false
                Start-Process -FilePath PowerShell.exe `
                    -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File ""$PSCommandPath"" -TargetPath ""$exe"" -ShortcutName ""$shortName""" `
                    -Verb RunAs
                return
            }

            $taskName = Get-TaskNameFromPath -ExePath $exe
            $txtLog.AppendText("[..] Creating scheduled task: $taskName`r`n")

            New-SilentTask -ExePath $exe -TaskName $taskName
            $txtLog.AppendText("[OK] Scheduled task created.`r`n")

            $lnk = New-LauncherShortcut -ExePath $exe -TaskName $taskName -ShortcutName $shortName
            $txtLog.AppendText("[OK] Shortcut created: $lnk`r`n")
            $txtLog.AppendText("[DONE] Double-click '$shortName' on your desktop to launch without UAC!`r`n")

            Local:Refresh-TaskList
        } catch {
            $txtLog.AppendText("[ERR] $($_.Exception.Message)`r`n")
        }
    })

    # Remove click handler
    $btnRemove.Add_Click({
        if ($listTasks.SelectedItems.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show(
                'Select a task from the list first.', 'UAC Silent Launcher', 'OK', 'Warning')
            return
        }
        $taskName = $listTasks.SelectedItems[0].Text
        $result = [System.Windows.Forms.MessageBox]::Show(
            "Delete task '$taskName' and its desktop shortcut?", 'Confirm', 'YesNo', 'Question')
        if ($result -eq 'Yes') {
            try {
                if (-not (Test-IsAdmin)) {
                    Start-Process -FilePath PowerShell.exe `
                        -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File ""$PSCommandPath"" -Remove -RemoveTaskName ""$taskName""" `
                        -Verb RunAs
                    return
                }
                Remove-SilentTask -TaskName $taskName
                $txtLog.AppendText("[OK] Removed: $taskName`r`n")
                Local:Refresh-TaskList
            } catch {
                $txtLog.AppendText("[ERR] $($_.Exception.Message)`r`n")
            }
        }
    })

    # Init
    Local:Refresh-TaskList
    $txtLog.AppendText("[OK] UAC Silent Launcher ready.`r`n")
    if (-not (Test-IsAdmin)) {
        $txtLog.AppendText("[!] Creating/removing tasks will auto-request admin privileges.`r`n")
    } else {
        $txtLog.AppendText("[OK] Running with admin rights.`r`n")
    }

    $form.ShowDialog() | Out-Null
}

# ============================================================
# CLI Mode
# ============================================================

function Invoke-CommandLine {
    if ($List) {
        Write-Host ''
        Write-Host '===== Existing Silent Tasks =====' -ForegroundColor Cyan
        $tasks = Get-ExistingSilentTasks
        if ($tasks.Count -eq 0) {
            Write-Host '  (none)' -ForegroundColor Gray
        } else {
            foreach ($t in $tasks) {
                Write-Host "  $($t.TaskName)  |  $($t.AppName)  |  $($t.Status)"
            }
        }
        Write-Host ''
        return
    }

    if ($Remove) {
        $tn = $RemoveTaskName
        if (-not $tn) {
            Write-Host 'Error: -RemoveTaskName is required' -ForegroundColor Red
            return
        }
        if (-not (Test-IsAdmin)) {
            Write-Host 'Requesting admin...' -ForegroundColor Yellow
            Start-Process -FilePath PowerShell.exe `
                -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File ""$PSCommandPath"" -Remove -RemoveTaskName ""$tn""" `
                -Verb RunAs
            return
        }
        try {
            Remove-SilentTask -TaskName $tn
            Write-Host "Removed: $tn" -ForegroundColor Green
        } catch {
            Write-Host "Failed: $_" -ForegroundColor Red
        }
        return
    }

    if ($TargetPath) {
        $exe = $TargetPath
        $shortName = if ($ShortcutName) { $ShortcutName } else {
            [System.IO.Path]::GetFileNameWithoutExtension($exe) + ' (Silent Launch)'
        }

        if (-not (Test-Path $exe)) {
            Write-Host "File not found: $exe" -ForegroundColor Red
            return
        }
        if (-not (Test-IsAdmin)) {
            Write-Host 'Requesting admin...' -ForegroundColor Yellow
            Start-Process -FilePath PowerShell.exe `
                -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File ""$PSCommandPath"" -TargetPath ""$exe"" -ShortcutName ""$shortName""" `
                -Verb RunAs
            return
        }

        $taskName = Get-TaskNameFromPath -ExePath $exe
        Write-Host "Creating task: $taskName" -ForegroundColor Cyan
        New-SilentTask -ExePath $exe -TaskName $taskName
        Write-Host 'Task created.' -ForegroundColor Green

        $lnk = New-LauncherShortcut -ExePath $exe -TaskName $taskName -ShortcutName $shortName
        Write-Host "Shortcut: $lnk" -ForegroundColor Green
        Write-Host 'Done!' -ForegroundColor Green
        return
    }

    # Default: launch GUI
    Show-GUI
}

# ============================================================
# Entry Point
# ============================================================

# On first run, check if running from console or should launch GUI
if ($Host.Name -match 'Console' -and (-not $TargetPath) -and (-not $List) -and (-not $Remove)) {
    # No params in console: launch GUI in new window to avoid blocking
    Start-Process -FilePath PowerShell.exe `
        -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""$PSCommandPath"" -Gui" `
        -WindowStyle Hidden
    return
}

Invoke-CommandLine
