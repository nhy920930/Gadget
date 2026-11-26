<#
.SYNOPSIS
    Balloon tip for the toolbox's scheduled reminder.

.DESCRIPTION
    The toolbox used to inline this whole snippet into -Command ("Add-Type ... ;
    New-Object NotifyIcon ..."). A hidden window plus -ExecutionPolicy Bypass plus an
    inline script block is exactly the shape security suites flag, so the call is now a
    plain "-File <script>" with fixed parameters: stable, readable, easy to whitelist.

    Keep this file ASCII-only. The toolbox ships it as-is and some machines still run
    Windows PowerShell with a legacy code page.
#>
param(
    [string] $Title = 'Reminder',
    [string] $Message = 'Time is up.',
    [int] $Seconds = 12
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$icon = New-Object System.Windows.Forms.NotifyIcon
try {
    $icon.Icon = [System.Drawing.SystemIcons]::Information
    $icon.Visible = $true
    $icon.ShowBalloonTip(10000, $Title, $Message, [System.Windows.Forms.ToolTipIcon]::Info)
    [System.Media.SystemSounds]::Exclamation.Play()
    Start-Sleep -Seconds $Seconds
}
finally {
    $icon.Visible = $false
    $icon.Dispose()
}
