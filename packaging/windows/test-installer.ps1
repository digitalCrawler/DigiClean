# Checks that DigiClean-Windows-Setup.exe installs DigiClean like a proper
# Windows application, then uninstalls it cleanly:
#   program files, Start menu entry, desktop shortcut, Settings > Apps entry
#   (name, version, publisher, icon), and that all of it is gone afterwards.
#
# Usage:
#   pwsh packaging/windows/test-installer.ps1 [-Setup dist\DigiClean-Windows-Setup.exe] [-AllUsers] [-Version 1.2.0]
# -AllUsers needs an elevated shell (CI runners are); without it the
# per-user ("Install for me only") mode is tested.
param(
    [string]$Setup = "dist\DigiClean-Windows-Setup.exe",
    [switch]$AllUsers,
    [string]$Version
)
$ErrorActionPreference = "Stop"
$setupPath = (Resolve-Path $Setup).Path
$appId = "{8F3A2C1E-6B4D-4E7A-9C2F-1D5E8A7B3C40}_is1"
$hive = if ($AllUsers) { "HKLM:" } else { "HKCU:" }
$uninstallKey = "$hive\Software\Microsoft\Windows\CurrentVersion\Uninstall\$appId"
$programs = [Environment]::GetFolderPath($(if ($AllUsers) { "CommonPrograms" } else { "Programs" }))
$desktop = [Environment]::GetFolderPath($(if ($AllUsers) { "CommonDesktopDirectory" } else { "DesktopDirectory" }))
$startLink = Join-Path $programs "DigiClean.lnk"
$desktopLink = Join-Path $desktop "DigiClean.lnk"
$failures = @()
function Check([bool]$ok, [string]$what) {
    if ($ok) { Write-Host "  ok    $what" } else { Write-Host "  FAIL  $what"; $script:failures += $what }
}

if (Test-Path $uninstallKey) { throw "DigiClean is already installed in this mode; uninstall it first." }

$log = Join-Path $env:TEMP "digiclean-setup-test.log"
$mode = if ($AllUsers) { "/ALLUSERS" } else { "/CURRENTUSER" }
Write-Host "Installing ($mode)..."
$p = Start-Process $setupPath -ArgumentList "/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART", $mode, "/TASKS=desktopicon", "/LOG=`"$log`"" -Wait -PassThru
if ($p.ExitCode -ne 0) { throw "Setup exited with $($p.ExitCode); log: $log" }

$entry = Get-ItemProperty $uninstallKey -ErrorAction SilentlyContinue
Check ($null -ne $entry) "Settings > Apps entry"
$dir = if ($entry) { $entry.InstallLocation.TrimEnd('\') } else { "" }
foreach ($file in "digiclean.exe", "digiclean_bridge.dll", "digiclean-check.exe", "flutter_windows.dll", "data\icudtl.dat") {
    Check (Test-Path (Join-Path $dir $file)) "installed $file"
}
if ($entry) {
    Check ($entry.DisplayName -eq "DigiClean") "Apps entry name ($($entry.DisplayName))"
    Check ($entry.Publisher -ne $null -and $entry.Publisher -ne "") "Apps entry publisher ($($entry.Publisher))"
    Check ($entry.DisplayIcon -like "*digiclean.exe*") "Apps entry icon"
    Check ([int]$entry.EstimatedSize -gt 0) "Apps entry size ($([math]::Round([int]$entry.EstimatedSize / 1024)) MB)"
    if ($Version) { Check ($entry.DisplayVersion -eq $Version) "Apps entry version ($($entry.DisplayVersion))" }
    if ($AllUsers) { Check ($dir -like "$env:ProgramFiles*") "installed under Program Files ($dir)" }
}
$shell = New-Object -ComObject WScript.Shell
foreach ($link in $startLink, $desktopLink) {
    $exists = Test-Path $link
    Check $exists "shortcut $link"
    if ($exists) { Check ($shell.CreateShortcut($link).TargetPath -like "*\digiclean.exe") "shortcut target of $(Split-Path $link -Leaf)" }
}

Write-Host "Uninstalling..."
if ($entry) {
    $uninstaller = $entry.UninstallString.Trim('"')
    Start-Process $uninstaller -ArgumentList "/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART" -Wait
    # The uninstaller hands over to a copy of itself; wait for it to finish.
    $deadline = (Get-Date).AddSeconds(90)
    while ((Test-Path $uninstallKey) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 500 }
    while ((Test-Path (Join-Path $dir "digiclean.exe")) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 500 }
}
Check (-not (Test-Path $uninstallKey)) "Apps entry removed"
Check (-not (Test-Path (Join-Path $dir "digiclean.exe"))) "program files removed"
Check (-not (Test-Path $startLink)) "Start menu entry removed"
Check (-not (Test-Path $desktopLink)) "desktop shortcut removed"

if ($failures.Count) { throw "$($failures.Count) installer check(s) failed: $($failures -join '; ')" }
Write-Host "Installer test passed."
