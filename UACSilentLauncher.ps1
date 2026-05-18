<#
.SYNOPSIS
  UAC 静默提权工具 — 为指定程序创建无需 UAC 弹窗的启动快捷方式

.DESCRIPTION
  利用 Windows 任务计划程序为白名单程序实现静默提权。
  不改系统安全设置，仅对目标程序单独生效。
  支持 GUI 和命令行两种使用方式。

.PARAMETER TargetPath
  目标 exe 的完整路径（命令行模式）

.PARAMETER ShortcutName
  快捷方式名称，不指定则自动生成

.PARAMETER Remove
  删除指定名称的静默任务及快捷方式（命令行模式）

.PARAMETER RemoveTaskName
  要删除的任务名称

.PARAMETER List
  列出所有已创建的静默任务

.EXAMPLE
  .\UACSilentLauncher.ps1                           # 启动 GUI
  .\UACSilentLauncher.ps1 -TargetPath "C:\WeGame\WeGame.exe"  # 命令行创建
  .\UACSilentLauncher.ps1 -Remove -RemoveTaskName "UACSilent_WeGame"  # 命令行删除
  .\UACSilentLauncher.ps1 -List                      # 列出所有任务
#>

param(
    [string]$TargetPath,
    [string]$ShortcutName,
    [switch]$Remove,
    [string]$RemoveTaskName,
    [switch]$List
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# ============================================================
# 核心功能函数
# ============================================================

function Get-TaskNameFromPath {
    param([string]$ExePath)
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($ExePath)
    return "UACSilent_$baseName"
}

function Get-SafeAppName {
    param([string]$ExePath)
    $name = [System.IO.Path]::GetFileNameWithoutExtension($ExePath)
    $name = $name -replace '[^\w一-鿿\-]', ''
    return $name
}

function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $time = Get-Date -Format "HH:mm:ss"
    $prefix = switch ($Level) {
        "OK"    { "[✓]" }
        "ERR"   { "[✗]" }
        "WARN"  { "[!]" }
        default { "[ ]" }
    }
    "$time $prefix $Message"
}

function Get-ExistingSilentTasks {
    $tasks = @()
    $allTasks = schtasks /query /fo CSV /v 2>$null | ConvertFrom-Csv 2>$null
    if ($allTasks) {
        foreach ($t in $allTasks) {
            if ($t.TaskName -like "UACSilent_*") {
                $tasks += [PSCustomObject]@{
                    TaskName     = $t.TaskName
                    AppName      = $t.TaskName -replace '^UACSilent_', ''
                    Status       = $t.Status
                }
            }
        }
    }
    return $tasks
}

function Get-ExeIcon {
    param([string]$ExePath)
    try {
        $icon = [System.Drawing.Icon]::ExtractAssociatedIcon($ExePath)
        if ($icon) {
            $icoPath = "$env:TEMP\$([System.IO.Path]::GetFileNameWithoutExtension($ExePath)).ico"
            $stream = [System.IO.File]::OpenWrite($icoPath)
            $icon.Save($stream)
            $stream.Close()
            $icon.Dispose()
            return $icoPath
        }
    } catch { }
    return $null
}

function New-SilentTask {
    param(
        [string]$ExePath,
        [string]$TaskName,
        [string]$AppName
    )

    if (-not (Test-Path $ExePath)) {
        throw "文件不存在: $ExePath"
    }

    $user = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    $exeDir = Split-Path -Parent $ExePath

    # 删除已有同名任务
    schtasks /delete /tn "$TaskName" /f 2>$null

    # 创建计划任务
    $createResult = schtasks /create `
        /tn "$TaskName" `
        /tr "`"$ExePath`"" `
        /sc ONCE `
        /st 00:00 `
        /ru "$user" `
        /rl HIGHEST `
        /f `
        2>&1

    if ($LASTEXITCODE -ne 0) {
        throw "创建计划任务失败: $createResult"
    }

    return $true
}

function Remove-SilentTask {
    param([string]$TaskName)

    $exists = schtasks /query /tn "$TaskName" 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw "任务不存在: $TaskName"
    }

    schtasks /delete /tn "$TaskName" /f 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "删除任务失败: $TaskName"
    }

    # 删除桌面快捷方式
    $desktop = [Environment]::GetFolderPath("Desktop")
    $lnkPath = Join-Path $desktop "$TaskName.lnk"
    if (Test-Path $lnkPath) {
        Remove-Item $lnkPath -Force
    }

    return $true
}

function New-LauncherShortcut {
    param(
        [string]$ExePath,
        [string]$TaskName,
        [string]$ShortcutName,
        [string]$DesktopPath
    )

    $lnkPath = Join-Path $DesktopPath "$ShortcutName.lnk"

    $WshShell = New-Object -ComObject WScript.Shell
    $Shortcut = $WshShell.CreateShortcut($lnkPath)

    # 目标指向 schtasks
    $Shortcut.TargetPath = "schtasks.exe"
    $Shortcut.Arguments = "/run /tn `"$TaskName`""
    $Shortcut.WorkingDirectory = Split-Path -Parent $ExePath

    # 提取图标
    $icoPath = Get-ExeIcon -ExePath $ExePath
    if ($icoPath -and (Test-Path $icoPath)) {
        $Shortcut.IconLocation = $icoPath
    } else {
        $Shortcut.IconLocation = "$ExePath,0"
    }

    # 运行方式
    $Shortcut.WindowStyle = 7  # 最小化，避免 schtasks 黑窗闪过
    $Shortcut.Description = "静默提权启动 $ShortcutName（无需UAC确认）"
    $Shortcut.Save()

    return $lnkPath
}

# ============================================================
# GUI 模式
# ============================================================

function Show-GUI {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    # --- 主窗口 ---
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "UAC 静默提权工具 v1.0"
    $form.Size = New-Object System.Drawing.Size(600, 500)
    $form.StartPosition = "CenterScreen"
    $form.FormBorderStyle = "FixedSingle"
    $form.MaximizeBox = $false
    $form.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 9)

    # --- 说明 Label ---
    $lblTitle = New-Object System.Windows.Forms.Label
    $lblTitle.Text = "为指定程序创建无需 UAC 弹窗的启动快捷方式"
    $lblTitle.Location = New-Object System.Drawing.Point(20, 15)
    $lblTitle.Size = New-Object System.Drawing.Size(540, 25)
    $lblTitle.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 10, [System.Drawing.FontStyle]::Bold)
    $form.Controls.Add($lblTitle)

    # --- 目标程序 ---
    $lblTarget = New-Object System.Windows.Forms.Label
    $lblTarget.Text = "目标程序 (.exe):"
    $lblTarget.Location = New-Object System.Drawing.Point(20, 55)
    $lblTarget.Size = New-Object System.Drawing.Size(200, 20)
    $form.Controls.Add($lblTarget)

    $txtTarget = New-Object System.Windows.Forms.TextBox
    $txtTarget.Location = New-Object System.Drawing.Point(20, 78)
    $txtTarget.Size = New-Object System.Drawing.Size(440, 23)
    $txtTarget.AllowDrop = $true
    $form.Controls.Add($txtTarget)

    # 拖放支持
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

    $btnBrowse = New-Object System.Windows.Forms.Button
    $btnBrowse.Text = "浏览..."
    $btnBrowse.Location = New-Object System.Drawing.Point(470, 76)
    $btnBrowse.Size = New-Object System.Drawing.Size(100, 27)
    $btnBrowse.Add_Click({
        $dlg = New-Object System.Windows.Forms.OpenFileDialog
        $dlg.Filter = "可执行文件 (*.exe)|*.exe|所有文件 (*.*)|*.*"
        $dlg.Title = "选择目标程序"
        if ($dlg.ShowDialog() -eq "OK") {
            $txtTarget.Text = $dlg.FileName
            $txtShortName.Text = "$([System.IO.Path]::GetFileNameWithoutExtension($dlg.FileName)) (静默启动)"
        }
    })
    $form.Controls.Add($btnBrowse)

    # --- 快捷方式名称 ---
    $lblShort = New-Object System.Windows.Forms.Label
    $lblShort.Text = "快捷方式名称:"
    $lblShort.Location = New-Object System.Drawing.Point(20, 118)
    $lblShort.Size = New-Object System.Drawing.Size(200, 20)
    $form.Controls.Add($lblShort)

    $txtShortName = New-Object System.Windows.Forms.TextBox
    $txtShortName.Location = New-Object System.Drawing.Point(20, 141)
    $txtShortName.Size = New-Object System.Drawing.Size(440, 23)
    $txtShortName.Text = ""
    $form.Controls.Add($txtShortName)

    # 自动填充名称
    $txtTarget.Add_TextChanged({
        if ($txtTarget.Text -and [System.IO.Path]::GetExtension($txtTarget.Text) -eq ".exe") {
            $txtShortName.Text = "$([System.IO.Path]::GetFileNameWithoutExtension($txtTarget.Text)) (静默启动)"
        }
    })

    # --- 按钮区 ---
    $btnCreate = New-Object System.Windows.Forms.Button
    $btnCreate.Text = "创建静默启动快捷方式"
    $btnCreate.Location = New-Object System.Drawing.Point(20, 185)
    $btnCreate.Size = New-Object System.Drawing.Size(200, 36)
    $btnCreate.BackColor = [System.Drawing.Color]::FromArgb(37, 99, 235)
    $btnCreate.ForeColor = [System.Drawing.Color]::White
    $btnCreate.FlatStyle = "Flat"
    $btnCreate.FlatAppearance.BorderSize = 0
    $form.Controls.Add($btnCreate)

    $btnRemove = New-Object System.Windows.Forms.Button
    $btnRemove.Text = "删除选中的静默任务"
    $btnRemove.Location = New-Object System.Drawing.Point(230, 185)
    $btnRemove.Size = New-Object System.Drawing.Size(200, 36)
    $btnRemove.BackColor = [System.Drawing.Color]::FromArgb(239, 68, 68)
    $btnRemove.ForeColor = [System.Drawing.Color]::White
    $btnRemove.FlatStyle = "Flat"
    $btnRemove.FlatAppearance.BorderSize = 0
    $form.Controls.Add($btnRemove)

    $btnRefresh = New-Object System.Windows.Forms.Button
    $btnRefresh.Text = "刷新列表"
    $btnRefresh.Location = New-Object System.Drawing.Point(440, 185)
    $btnRefresh.Size = New-Object System.Drawing.Size(130, 36)
    $form.Controls.Add($btnRefresh)

    # --- 已有任务列表 ---
    $lblList = New-Object System.Windows.Forms.Label
    $lblList.Text = "已创建的静默任务:"
    $lblList.Location = New-Object System.Drawing.Point(20, 240)
    $lblList.Size = New-Object System.Drawing.Size(200, 20)
    $form.Controls.Add($lblList)

    $listTasks = New-Object System.Windows.Forms.ListView
    $listTasks.Location = New-Object System.Drawing.Point(20, 263)
    $listTasks.Size = New-Object System.Drawing.Size(550, 120)
    $listTasks.View = "Details"
    $listTasks.FullRowSelect = $true
    $listTasks.GridLines = $true
    $listTasks.Columns.Add("任务名称", 220)
    $listTasks.Columns.Add("程序名称", 200)
    $listTasks.Columns.Add("状态", 110)
    $form.Controls.Add($listTasks)

    # --- 日志区 ---
    $lblLog = New-Object System.Windows.Forms.Label
    $lblLog.Text = "操作日志:"
    $lblLog.Location = New-Object System.Drawing.Point(20, 393)
    $lblLog.Size = New-Object System.Drawing.Size(100, 20)
    $form.Controls.Add($lblLog)

    $txtLog = New-Object System.Windows.Forms.TextBox
    $txtLog.Location = New-Object System.Drawing.Point(20, 413)
    $txtLog.Size = New-Object System.Drawing.Size(550, 45)
    $txtLog.Multiline = $true
    $txtLog.ScrollBars = "Vertical"
    $txtLog.ReadOnly = $true
    $txtLog.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
    $txtLog.ForeColor = [System.Drawing.Color]::FromArgb(0, 200, 0)
    $txtLog.Font = New-Object System.Drawing.Font("Consolas", 8)
    $form.Controls.Add($txtLog)

    # --- 功能：刷新列表 ---
    function Refresh-TaskList {
        $listTasks.Items.Clear()
        $tasks = Get-ExistingSilentTasks
        foreach ($t in $tasks) {
            $item = New-Object System.Windows.Forms.ListViewItem($t.TaskName)
            $item.SubItems.Add($t.AppName)
            $item.SubItems.Add($t.Status)
            $listTasks.Items.Add($item)
        }
        $txtLog.AppendText("$(Write-Log "已刷新任务列表" "INFO")`r`n")
    }

    $btnRefresh.Add_Click({ Refresh-TaskList })

    # --- 功能：创建 ---
    $btnCreate.Add_Click({
        $exe = $txtTarget.Text.Trim()
        $shortName = $txtShortName.Text.Trim()

        if (-not $exe) {
            [System.Windows.Forms.MessageBox]::Show("请选择目标程序", "提示", "OK", "Warning")
            return
        }
        if (-not (Test-Path $exe)) {
            [System.Windows.Forms.MessageBox]::Show("文件不存在: $exe", "错误", "OK", "Error")
            return
        }
        if ([System.IO.Path]::GetExtension($exe) -ne ".exe") {
            [System.Windows.Forms.MessageBox]::Show("只能选择 .exe 文件", "错误", "OK", "Error")
            return
        }
        if (-not $shortName) {
            $shortName = "$([System.IO.Path]::GetFileNameWithoutExtension($exe)) (静默启动)"
        }

        try {
            if (-not (Test-IsAdmin)) {
                $txtLog.AppendText("$(Write-Log "需要管理员权限，正在请求提升..." "WARN")`r`n")
                $form.TopMost = $false
                Start-Process -FilePath PowerShell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -TargetPath `"$exe`" -ShortcutName `"$shortName`"" -Verb RunAs
                return
            }

            $taskName = Get-TaskNameFromPath -ExePath $exe
            $txtLog.AppendText("$(Write-Log "正在创建计划任务: $taskName" "INFO")`r`n")

            New-SilentTask -ExePath $exe -TaskName $taskName -AppName (Get-SafeAppName $exe)
            $txtLog.AppendText("$(Write-Log "计划任务已创建" "OK")`r`n")

            $desktop = [Environment]::GetFolderPath("Desktop")
            $lnk = New-LauncherShortcut -ExePath $exe -TaskName $taskName -ShortcutName $shortName -DesktopPath $desktop
            $txtLog.AppendText("$(Write-Log "快捷方式已创建: $lnk" "OK")`r`n")
            $txtLog.AppendText("$(Write-Log "完成！双击桌面上的 '$shortName' 即可静默启动" "OK")`r`n")

            Refresh-TaskList
        } catch {
            $txtLog.AppendText("$(Write-Log $_.Exception.Message "ERR")`r`n")
        }
    })

    # --- 功能：删除 ---
    $btnRemove.Add_Click({
        if ($listTasks.SelectedItems.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show("请先在列表中选择一个任务", "提示", "OK", "Warning")
            return
        }
        $taskName = $listTasks.SelectedItems[0].Text
        $confirm = [System.Windows.Forms.MessageBox]::Show("确定要删除任务 '$taskName' 及其桌面快捷方式吗？", "确认删除", "YesNo", "Question")
        if ($confirm -eq "Yes") {
            try {
                if (-not (Test-IsAdmin)) {
                    Start-Process -FilePath PowerShell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Remove -RemoveTaskName `"$taskName`"" -Verb RunAs
                    return
                }
                Remove-SilentTask -TaskName $taskName
                $txtLog.AppendText("$(Write-Log "已删除: $taskName" "OK")`r`n")
                Refresh-TaskList
            } catch {
                $txtLog.AppendText("$(Write-Log $_.Exception.Message "ERR")`r`n")
            }
        }
    })

    # --- 初始化 ---
    Refresh-TaskList
    $txtLog.AppendText("$(Write-Log "UAC 静默提权工具已就绪" "INFO")`r`n")
    if (-not (Test-IsAdmin)) {
        $txtLog.AppendText("$(Write-Log "提示: 创建/删除任务需要管理员权限，点击按钮时会自动提升" "WARN")`r`n")
    } else {
        $txtLog.AppendText("$(Write-Log "当前以管理员权限运行" "OK")`r`n")
    }

    $form.ShowDialog() | Out-Null
}

# ============================================================
# 命令行模式
# ============================================================

function Invoke-CommandLine {
    if ($List) {
        Write-Host ""
        Write-Host "===== 已创建的静默任务 =====" -ForegroundColor Cyan
        $tasks = Get-ExistingSilentTasks
        if ($tasks.Count -eq 0) {
            Write-Host "  (无)" -ForegroundColor Gray
        } else {
            foreach ($t in $tasks) {
                Write-Host "  $($t.TaskName)  |  $($t.AppName)  |  $($t.Status)"
            }
        }
        Write-Host ""
        return
    }

    if ($Remove) {
        $tn = $RemoveTaskName
        if (-not $tn) {
            Write-Host "错误: 必须指定 -RemoveTaskName" -ForegroundColor Red
            return
        }
        if (-not (Test-IsAdmin)) {
            Write-Host "需要管理员权限，正在提升..." -ForegroundColor Yellow
            Start-Process -FilePath PowerShell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Remove -RemoveTaskName `"$tn`"" -Verb RunAs
            return
        }
        try {
            Remove-SilentTask -TaskName $tn
            Write-Host "已删除: $tn" -ForegroundColor Green
        } catch {
            Write-Host "删除失败: $_" -ForegroundColor Red
        }
        return
    }

    if ($TargetPath) {
        $exe = $TargetPath
        $shortName = if ($ShortcutName) { $ShortcutName } else { "$([System.IO.Path]::GetFileNameWithoutExtension($exe)) (静默启动)" }

        if (-not (Test-Path $exe)) {
            Write-Host "文件不存在: $exe" -ForegroundColor Red
            return
        }
        if (-not (Test-IsAdmin)) {
            Write-Host "需要管理员权限，正在提升..." -ForegroundColor Yellow
            Start-Process -FilePath PowerShell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -TargetPath `"$exe`" -ShortcutName `"$shortName`"" -Verb RunAs
            return
        }

        $taskName = Get-TaskNameFromPath -ExePath $exe
        Write-Host "创建计划任务: $taskName" -ForegroundColor Cyan
        New-SilentTask -ExePath $exe -TaskName $taskName -AppName (Get-SafeAppName $exe)
        Write-Host "计划任务已创建" -ForegroundColor Green

        $desktop = [Environment]::GetFolderPath("Desktop")
        $lnk = New-LauncherShortcut -ExePath $exe -TaskName $taskName -ShortcutName $shortName -DesktopPath $desktop
        Write-Host "快捷方式已创建: $lnk" -ForegroundColor Green
        Write-Host "完成！" -ForegroundColor Green
        return
    }

    # 无参数时启动 GUI
    Show-GUI
}

# ============================================================
# 入口
# ============================================================
Invoke-CommandLine
