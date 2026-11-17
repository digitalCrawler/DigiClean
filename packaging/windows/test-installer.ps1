# Checks that DigiClean-Windows-Setup.exe installs DigiClean like a proper
# Windows application, then uninstalls it cleanly:
#   program files, Start menu entry, desktop shortcut, Settings > Apps entry
#   (name, version, publisher, icon), and that all of it is gone afterwards.
#
# With -Previous it checks an update instead: it installs that older setup,
# starts the old DigiClean, then runs this setup over it and checks that the
# running app was closed and the same installation was updated in place (one
# Apps entry, the new version, no files left from the old version).
#
# Usage:
#   pwsh packaging/windows/test-installer.ps1 [-Setup dist\DigiClean-Windows-Setup.exe] [-AllUsers] [-Version 1.2.0] [-Previous old-setup.exe]
# -AllUsers needs an elevated shell (CI runners are); without it the
# per-user ("Install for me only") mode is tested.
param(
    [string]$Setup = "dist\DigiClean-Windows-Setup.exe",
    [switch]$AllUsers,
    [string]$Version,
    [string]$Previous
)
$ErrorActionPreference = "Stop"
$setupPath = (Resolve-Path $Setup).Path
$appId = "{8F3A2C1E-6B4D-4E7A-9C2F-1D5E8A7B3C40}_is1"
$hive = if ($AllUsers) { "HKLM:" } else { "HKCU:" }
$otherHive = if ($AllUsers) { "HKCU:" } else { "HKLM:" }
$uninstallKey = "$hive\Software\Microsoft\Windows\CurrentVersion\Uninstall\$appId"
$otherKey = "$otherHive\Software\Microsoft\Windows\CurrentVersion\Uninstall\$appId"
$programs = [Environment]::GetFolderPath($(if ($AllUsers) { "CommonPrograms" } else { "Programs" }))
$desktop = [Environment]::GetFolderPath($(if ($AllUsers) { "CommonDesktopDirectory" } else { "DesktopDirectory" }))
$startLink = Join-Path $programs "DigiClean.lnk"
$desktopLink = Join-Path $desktop "DigiClean.lnk"
$failures = @()
function Check([bool]$ok, [string]$what) {
    if ($ok) { Write-Host "  ok    $what" } else { Write-Host "  FAIL  $what"; $script:failures += $what }
}
$mode = if ($AllUsers) { "/ALLUSERS" } else { "/CURRENTUSER" }
function Install([string]$exe, [string]$name) {
    $log = Join-Path $env:TEMP "digiclean-setup-test-$name.log"
    Write-Host "Installing $name ($mode)..."
    $p = Start-Process $exe -ArgumentList "/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART", $mode, "/TASKS=desktopicon", "/LOG=`"$log`"" -Wait -PassThru
    if ($p.ExitCode -ne 0) { throw "Setup exited with $($p.ExitCode); log: $log" }
}

if (Test-Path $uninstallKey) { throw "DigiClean is already installed in this mode; uninstall it first." }
$otherBefore = Test-Path $otherKey

if ($Previous) {
    Install (Resolve-Path $Previous).Path "previous"
    $old = Get-ItemProperty $uninstallKey
    $oldDir = $old.InstallLocation.TrimEnd('\')
    Write-Host "  previous version $($old.DisplayVersion) in $oldDir"
    # Stands in for an asset the new version no longer ships.
    $stale = Join-Path $oldDir "data\flutter_assets\removed-in-new-version.txt"
    Set-Content $stale "left over from the previous version"
    # Update while the old version is open, as users do.
    $running = Start-Process (Join-Path $oldDir "digiclean.exe") -PassThru
    Start-Sleep -Seconds 5
    Check (-not $running.HasExited) "previous version running before the update"
}
Install $setupPath $(if ($Previous) { "update" } else { "new" })

$entry = Get-ItemProperty $uninstallKey -ErrorAction SilentlyContinue
Check ($null -ne $entry) "Settings > Apps entry"
Check ((Test-Path $otherKey) -eq $otherBefore) "no second installation in the other install mode"
$dir = if ($entry) { $entry.InstallLocation.TrimEnd('\') } else { "" }
foreach ($file in "digiclean.exe", "digiclean_bridge.dll", "digiclean-check.exe", "flutter_windows.dll", "data\icudtl.dat", "data\flutter_assets\AssetManifest.bin") {
    Check (Test-Path (Join-Path $dir $file)) "installed $file"
}
if ($entry) {
    Check ($entry.DisplayName -eq "DigiClean") "Apps entry name ($($entry.DisplayName))"
    Check ($entry.Publisher -ne $null -and $entry.Publisher -ne "") "Apps entry publisher ($($entry.Publisher))"
    Check ($entry.DisplayIcon -like "*digiclean.exe*") "Apps entry icon"
    Check ([int]$entry.EstimatedSize -gt 0) "Apps entry size ($([math]::Round([int]$entry.EstimatedSize / 1024)) MB)"
    if ($Version) {
        Check ($entry.DisplayVersion -eq $Version) "Apps entry version ($($entry.DisplayVersion))"
        $exeVersion = "$((Get-Item (Join-Path $dir "digiclean.exe")).VersionInfo.ProductVersion)".Trim()
        Check (($exeVersion -split '\+')[0] -eq $Version) "digiclean.exe version ($exeVersion)"
    }
    if ($AllUsers) { Check ($dir -like "$env:ProgramFiles*") "installed under Program Files ($dir)" }
}
if ($Previous) {
    Check ($dir -eq $oldDir) "updated in place ($dir)"
    Check (-not (Test-Path $stale)) "files left from the previous version removed"
    Check (-not (Test-Path (Join-Path $dir "unins001.exe"))) "a single uninstaller"
    $running.Refresh()
    Check $running.HasExited "the running previous version was closed for the update"
    if (-not $running.HasExited) { Stop-Process -Id $running.Id -Force }
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
