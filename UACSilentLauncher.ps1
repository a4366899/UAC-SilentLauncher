<#
.SYNOPSIS
  UAC 静默启动工具 — 创建桌面快捷方式绕过 UAC 弹窗

.DESCRIPTION
  利用 Windows 任务计划程序实现白名单式静默提权。
  不修改系统安全设置，仅影响你选择的程序。

.PARAMETER TargetPath
  目标 .exe 的完整路径（命令行模式）

.PARAMETER ShortcutName
  快捷方式名称，不指定则自动生成

.PARAMETER Remove
  删除静默任务及其快捷方式（命令行模式，需配合 -RemoveTaskName）

.PARAMETER RemoveTaskName
  要删除的任务名称

.PARAMETER List
  列出所有已存在的静默任务

.EXAMPLE
  .\UACSilentLauncher.ps1                          # 启动 GUI
  .\UACSilentLauncher.ps1 -TargetPath "C:\app.exe" # 命令行：创建
  .\UACSilentLauncher.ps1 -List                     # 命令行：列出所有
  .\UACSilentLauncher.ps1 -Remove -RemoveTaskName "UACSilent_App"  # 命令行：删除
#>

param(
    [string]$TargetPath,
    [string]$ShortcutName,
    [switch]$Remove,
    [string]$RemoveTaskName,
    [switch]$List,
    [switch]$Gui
)

$ErrorActionPreference = "Stop"

# ============================================================
# 核心函数
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
        throw "文件未找到: $ExePath"
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
        throw "创建任务失败: $result"
    }
}

function Remove-SilentTask {
    param([string]$TaskName)

    schtasks /query /tn "$TaskName" 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "任务未找到: $TaskName"
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
    $form.Text = 'UAC 静默启动工具 v1.0'
    $form.Size = New-Object System.Drawing.Size(620, 500)
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = 'FixedSingle'
    $form.MaximizeBox = $false
    $form.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)

    # 标题
    $lblTitle = New-Object System.Windows.Forms.Label
    $lblTitle.Text = '把 .exe 拖进来，点创建，完事。不再弹 UAC 窗口。'
    $lblTitle.Location = New-Object System.Drawing.Point(16, 12)
    $lblTitle.Size = New-Object System.Drawing.Size(580, 24)
    $lblTitle.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10, [System.Drawing.FontStyle]::Bold)
    $form.Controls.Add($lblTitle)

    # 目标程序标签
    $lblTarget = New-Object System.Windows.Forms.Label
    $lblTarget.Text = '目标程序（.exe）：'
    $lblTarget.Location = New-Object System.Drawing.Point(16, 50)
    $lblTarget.Size = New-Object System.Drawing.Size(300, 20)
    $form.Controls.Add($lblTarget)

    # 目标路径文本框
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

    # 浏览按钮
    $btnBrowse = New-Object System.Windows.Forms.Button
    $btnBrowse.Text = '浏览...'
    $btnBrowse.Location = New-Object System.Drawing.Point(476, 70)
    $btnBrowse.Size = New-Object System.Drawing.Size(120, 27)
    $btnBrowse.Add_Click({
        $dlg = New-Object System.Windows.Forms.OpenFileDialog
        $dlg.Filter = '可执行文件 (*.exe)|*.exe|所有文件 (*.*)|*.*'
        $dlg.Title = '选择目标程序'
        if ($dlg.ShowDialog() -eq 'OK') {
            $txtTarget.Text = $dlg.FileName
            $name = [System.IO.Path]::GetFileNameWithoutExtension($dlg.FileName)
            $txtShortName.Text = "$name (静默启动)"
        }
    })
    $form.Controls.Add($btnBrowse)

    # 快捷方式名称标签
    $lblShort = New-Object System.Windows.Forms.Label
    $lblShort.Text = '快捷方式名称：'
    $lblShort.Location = New-Object System.Drawing.Point(16, 108)
    $lblShort.Size = New-Object System.Drawing.Size(300, 20)
    $form.Controls.Add($lblShort)

    # 快捷方式名称文本框
    $txtShortName = New-Object System.Windows.Forms.TextBox
    $txtShortName.Location = New-Object System.Drawing.Point(16, 130)
    $txtShortName.Size = New-Object System.Drawing.Size(450, 23)
    $form.Controls.Add($txtShortName)

    $txtTarget.Add_TextChanged({
        if ($txtTarget.Text -and (Test-Path $txtTarget.Text)) {
            $ext = [System.IO.Path]::GetExtension($txtTarget.Text)
            if ($ext -eq '.exe') {
                $name = [System.IO.Path]::GetFileNameWithoutExtension($txtTarget.Text)
                $txtShortName.Text = "$name (静默启动)"
            }
        }
    })

    # 创建按钮
    $btnCreate = New-Object System.Windows.Forms.Button
    $btnCreate.Text = '创建静默快捷方式'
    $btnCreate.Location = New-Object System.Drawing.Point(16, 175)
    $btnCreate.Size = New-Object System.Drawing.Size(200, 36)
    $btnCreate.BackColor = [System.Drawing.Color]::FromArgb(37, 99, 235)
    $btnCreate.ForeColor = [System.Drawing.Color]::White
    $btnCreate.FlatStyle = 'Flat'
    $btnCreate.FlatAppearance.BorderSize = 0
    $form.Controls.Add($btnCreate)

    # 删除按钮
    $btnRemove = New-Object System.Windows.Forms.Button
    $btnRemove.Text = '删除选中任务'
    $btnRemove.Location = New-Object System.Drawing.Point(226, 175)
    $btnRemove.Size = New-Object System.Drawing.Size(200, 36)
    $btnRemove.BackColor = [System.Drawing.Color]::FromArgb(239, 68, 68)
    $btnRemove.ForeColor = [System.Drawing.Color]::White
    $btnRemove.FlatStyle = 'Flat'
    $btnRemove.FlatAppearance.BorderSize = 0
    $form.Controls.Add($btnRemove)

    # 刷新按钮
    $btnRefresh = New-Object System.Windows.Forms.Button
    $btnRefresh.Text = '刷新列表'
    $btnRefresh.Location = New-Object System.Drawing.Point(436, 175)
    $btnRefresh.Size = New-Object System.Drawing.Size(160, 36)
    $form.Controls.Add($btnRefresh)

    # 任务列表标签
    $lblList = New-Object System.Windows.Forms.Label
    $lblList.Text = '已创建的静默任务：'
    $lblList.Location = New-Object System.Drawing.Point(16, 225)
    $lblList.Size = New-Object System.Drawing.Size(300, 20)
    $form.Controls.Add($lblList)

    # 任务列表视图
    $listTasks = New-Object System.Windows.Forms.ListView
    $listTasks.Location = New-Object System.Drawing.Point(16, 248)
    $listTasks.Size = New-Object System.Drawing.Size(580, 120)
    $listTasks.View = 'Details'
    $listTasks.FullRowSelect = $true
    $listTasks.GridLines = $true
    [void]$listTasks.Columns.Add('任务名称', 220)
    [void]$listTasks.Columns.Add('应用名称', 200)
    [void]$listTasks.Columns.Add('状态', 140)
    $form.Controls.Add($listTasks)

    # 日志标签
    $lblLog = New-Object System.Windows.Forms.Label
    $lblLog.Text = '日志：'
    $lblLog.Location = New-Object System.Drawing.Point(16, 380)
    $lblLog.Size = New-Object System.Drawing.Size(100, 18)
    $form.Controls.Add($lblLog)

    # 日志文本框
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
        $txtLog.AppendText("[OK] 任务列表已刷新。`r`n")
    }

    $btnRefresh.Add_Click({ Local:Refresh-TaskList })

    # 创建按钮点击事件
    $btnCreate.Add_Click({
        $exe = $txtTarget.Text.Trim()
        $shortName = $txtShortName.Text.Trim()

        if (-not $exe) {
            [System.Windows.Forms.MessageBox]::Show(
                '请选择目标 .exe 文件。', 'UAC 静默启动工具', 'OK', 'Warning')
            return
        }
        if (-not (Test-Path $exe)) {
            [System.Windows.Forms.MessageBox]::Show(
                "文件未找到：$exe", 'UAC 静默启动工具', 'OK', 'Error')
            return
        }
        if ([System.IO.Path]::GetExtension($exe) -ne '.exe') {
            [System.Windows.Forms.MessageBox]::Show(
                '仅支持 .exe 文件。', 'UAC 静默启动工具', 'OK', 'Error')
            return
        }
        if (-not $shortName) {
            $shortName = [System.IO.Path]::GetFileNameWithoutExtension($exe) + ' (静默启动)'
        }

        try {
            if (-not (Test-IsAdmin)) {
                $txtLog.AppendText("[..] 正在请求管理员权限...`r`n")
                $form.TopMost = $false
                Start-Process -FilePath PowerShell.exe `
                    -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File ""$PSCommandPath"" -TargetPath ""$exe"" -ShortcutName ""$shortName""" `
                    -Verb RunAs
                return
            }

            $taskName = Get-TaskNameFromPath -ExePath $exe
            $txtLog.AppendText("[..] 正在创建计划任务: $taskName`r`n")

            New-SilentTask -ExePath $exe -TaskName $taskName
            $txtLog.AppendText("[OK] 计划任务已创建。`r`n")

            $lnk = New-LauncherShortcut -ExePath $exe -TaskName $taskName -ShortcutName $shortName
            $txtLog.AppendText("[OK] 快捷方式已创建: $lnk`r`n")
            $txtLog.AppendText("[DONE] 双击桌面上的 '$shortName' 即可无 UAC 弹窗启动！`r`n")

            Local:Refresh-TaskList
        } catch {
            $txtLog.AppendText("[ERR] $($_.Exception.Message)`r`n")
        }
    })

    # 删除按钮点击事件
    $btnRemove.Add_Click({
        if ($listTasks.SelectedItems.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show(
                '请先从列表中选中一个任务。', 'UAC 静默启动工具', 'OK', 'Warning')
            return
        }
        $taskName = $listTasks.SelectedItems[0].Text
        $result = [System.Windows.Forms.MessageBox]::Show(
            "确定要删除任务 '$taskName' 及其桌面快捷方式吗？", '确认删除', 'YesNo', 'Question')
        if ($result -eq 'Yes') {
            try {
                if (-not (Test-IsAdmin)) {
                    Start-Process -FilePath PowerShell.exe `
                        -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File ""$PSCommandPath"" -Remove -RemoveTaskName ""$taskName""" `
                        -Verb RunAs
                    return
                }
                Remove-SilentTask -TaskName $taskName
                $txtLog.AppendText("[OK] 已删除: $taskName`r`n")
                Local:Refresh-TaskList
            } catch {
                $txtLog.AppendText("[ERR] $($_.Exception.Message)`r`n")
            }
        }
    })

    # 初始化
    Local:Refresh-TaskList
    $txtLog.AppendText("[OK] UAC 静默启动工具就绪。`r`n")
    if (-not (Test-IsAdmin)) {
        $txtLog.AppendText("[!] 创建/删除任务时将自动请求管理员权限。`r`n")
    } else {
        $txtLog.AppendText("[OK] 当前以管理员权限运行。`r`n")
    }

    $form.ShowDialog() | Out-Null
}

# ============================================================
# 命令行模式
# ============================================================

function Invoke-CommandLine {
    if ($Gui) {
        Show-GUI
        return
    }
    if ($List) {
        Write-Host ''
        Write-Host '===== 现有静默任务 =====' -ForegroundColor Cyan
        $tasks = Get-ExistingSilentTasks
        if ($tasks.Count -eq 0) {
            Write-Host '  (无)' -ForegroundColor Gray
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
            Write-Host '错误：需要 -RemoveTaskName 参数' -ForegroundColor Red
            return
        }
        if (-not (Test-IsAdmin)) {
            Write-Host '正在请求管理员权限...' -ForegroundColor Yellow
            Start-Process -FilePath PowerShell.exe `
                -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File ""$PSCommandPath"" -Remove -RemoveTaskName ""$tn""" `
                -Verb RunAs
            return
        }
        try {
            Remove-SilentTask -TaskName $tn
            Write-Host "已删除: $tn" -ForegroundColor Green
        } catch {
            Write-Host "失败: $_" -ForegroundColor Red
        }
        return
    }

    if ($TargetPath) {
        $exe = $TargetPath
        $shortName = if ($ShortcutName) { $ShortcutName } else {
            [System.IO.Path]::GetFileNameWithoutExtension($exe) + ' (静默启动)'
        }

        if (-not (Test-Path $exe)) {
            Write-Host "文件未找到: $exe" -ForegroundColor Red
            return
        }
        if (-not (Test-IsAdmin)) {
            Write-Host '正在请求管理员权限...' -ForegroundColor Yellow
            Start-Process -FilePath PowerShell.exe `
                -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File ""$PSCommandPath"" -TargetPath ""$exe"" -ShortcutName ""$shortName""" `
                -Verb RunAs
            return
        }

        $taskName = Get-TaskNameFromPath -ExePath $exe
        Write-Host "正在创建任务: $taskName" -ForegroundColor Cyan
        New-SilentTask -ExePath $exe -TaskName $taskName
        Write-Host '任务已创建。' -ForegroundColor Green

        $lnk = New-LauncherShortcut -ExePath $exe -TaskName $taskName -ShortcutName $shortName
        Write-Host "快捷方式: $lnk" -ForegroundColor Green
        Write-Host '完成！' -ForegroundColor Green
        return
    }

    # 默认：启动 GUI
    Show-GUI
}

# ============================================================
# 入口
# ============================================================

# 首次运行：检测是否从控制台启动，是否需要自启 GUI
if ($Host.Name -match 'Console' -and (-not $TargetPath) -and (-not $List) -and (-not $Remove) -and (-not $Gui)) {
    # 控制台无参数：在新窗口启动 GUI 避免阻塞
    Start-Process -FilePath PowerShell.exe `
        -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""$PSCommandPath"" -Gui" `
        -WindowStyle Hidden
    return
}

Invoke-CommandLine
