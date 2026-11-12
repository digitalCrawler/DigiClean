# Packages a Flutter Windows release build into:
#   dist/DigiClean-Windows-Setup.exe    (Inno Setup installer, if ISCC is available)
#   dist/DigiClean-Windows-Portable.zip (unzip and run)
#
# Usage:  pwsh packaging/windows/package.ps1 -Version 1.2.0 [-Url https://github.com/you/digiclean] [-Publisher "Your Name"]
# Run after `flutter build windows --release`. CI passes -Url and -Publisher
# (shown in Settings > Apps); signing uses WINDOWS_CERT_PFX_PATH and
# WINDOWS_CERT_PASSWORD when set.
param(
    [Parameter(Mandatory = $true)][string]$Version,
    [string]$BuildDir = "build\windows\x64\runner\Release",
    [string]$Dist = "dist",
    [string]$Url = $(if ($env:DIGICLEAN_URL) { $env:DIGICLEAN_URL } else { "https://github.com" }),
    [string]$Publisher = $(if ($env:DIGICLEAN_PUBLISHER) { $env:DIGICLEAN_PUBLISHER } else { "DigiClean" })
)
$ErrorActionPreference = "Stop"
$root = Resolve-Path (Join-Path $PSScriptRoot "..\..")
Set-Location $root

if (-not (Test-Path "$BuildDir\digiclean.exe")) {
    throw "No release build at $BuildDir - run 'flutter build windows --release' first."
}
New-Item -ItemType Directory -Force $Dist | Out-Null

# The app and the Rust engine link against the MSVC runtime, which is not on
# every PC. Ship it next to the executable (app-local deployment).
# Newest runtime across all installs with the C++ tools: a runtime at least as
# new as the compiler is required, and newer ones are backward compatible.
$vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
$crt = $null
if (Test-Path $vswhere) {
    $crt = & $vswhere -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath |
        ForEach-Object { Get-ChildItem "$_\VC\Redist\MSVC" -Directory -ErrorAction SilentlyContinue } |
        Where-Object { $_.Name -match '^\d+\.\d+\.\d+$' } |
        Sort-Object { [version]$_.Name } -Descending |
        ForEach-Object { Get-ChildItem "$($_.FullName)\x64" -Directory -Filter "Microsoft.VC*.CRT" -ErrorAction SilentlyContinue } |
        Select-Object -First 1
}
if ($crt) {
    foreach ($dll in "msvcp140.dll", "vcruntime140.dll", "vcruntime140_1.dll") {
        Copy-Item (Join-Path $crt.FullName $dll) $BuildDir -Force
    }
    Write-Host "Bundled C++ runtime from $($crt.FullName)"
} else {
    Write-Warning "MSVC runtime not found; users without the VC++ Redistributable will not be able to start the app."
}

# The background checker that Task Scheduler runs while the app is closed.
cargo build --release -p digiclean-cli --bin digiclean-check
if ($LASTEXITCODE -ne 0) { throw "building digiclean-check failed" }
Copy-Item "target\release\digiclean-check.exe" $BuildDir -Force

# Optional code signing (removes SmartScreen "unknown publisher" warnings).
$signtool = $null
if ($env:WINDOWS_CERT_PFX_PATH) {
    $signtool = (Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\bin" -Recurse -Filter signtool.exe |
        Where-Object { $_.FullName -match "\\x64\\" } | Sort-Object FullName -Descending | Select-Object -First 1).FullName
    if (-not $signtool) { throw "signtool.exe not found (Windows SDK)" }
}
function Sign-File([string]$path) {
    if (-not $signtool) { return }
    & $signtool sign /f $env:WINDOWS_CERT_PFX_PATH /p $env:WINDOWS_CERT_PASSWORD `
        /fd SHA256 /tr http://timestamp.digicert.com /td SHA256 $path
    if ($LASTEXITCODE -ne 0) { throw "signing $path failed" }
}
Sign-File "$BuildDir\digiclean.exe"
Sign-File "$BuildDir\digiclean_bridge.dll"
Sign-File "$BuildDir\digiclean-check.exe"

# Portable zip with a top-level DigiClean folder.
$staging = Join-Path $env:TEMP "digiclean-portable-$PID"
Remove-Item $staging -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory "$staging\DigiClean" | Out-Null
Copy-Item "$BuildDir\*" "$staging\DigiClean" -Recurse
$zip = Join-Path $Dist "DigiClean-Windows-Portable.zip"
Remove-Item $zip -Force -ErrorAction SilentlyContinue
Compress-Archive -Path "$staging\DigiClean" -DestinationPath $zip -CompressionLevel Optimal
Remove-Item $staging -Recurse -Force
Write-Host "Created $zip"

# Installer.
$iscc = Get-Command iscc -ErrorAction SilentlyContinue
if (-not $iscc) {
    foreach ($p in "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe", "$env:ProgramFiles\Inno Setup 6\ISCC.exe", "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe") {
        if (Test-Path $p) { $iscc = Get-Item $p; break }
    }
}
if ($iscc) {
    $isccPath = if ($iscc -is [System.Management.Automation.CommandInfo]) { $iscc.Source } else { $iscc.FullName }
    $isccArgs = @(
        "/DAppVersion=$Version", "/DSourceDir=$root\$BuildDir", "/DOutputDir=$root\$Dist",
        "/DAppURL=$Url", "/DPublisher=$Publisher"
    )
    if ($signtool) {
        # Inno Setup signs the installer and the uninstaller it embeds ($q = quote, $f = file).
        $isccArgs += "/DSign=1"
        $isccArgs += "/Ssigntool=`$q$signtool`$q sign /f `$q$($env:WINDOWS_CERT_PFX_PATH)`$q /p `$q$($env:WINDOWS_CERT_PASSWORD)`$q /fd SHA256 /tr http://timestamp.digicert.com /td SHA256 `$f"
    }
    & $isccPath @isccArgs "packaging\windows\digiclean.iss"
    if ($LASTEXITCODE -ne 0) { throw "Inno Setup failed" }
    Write-Host "Created $Dist\DigiClean-Windows-Setup.exe"
} else {
    Write-Warning "Inno Setup (ISCC) not found - skipped the installer. Install it from https://jrsoftware.org/isinfo.php"
}
