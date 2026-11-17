# Sets DigiClean's version everywhere it is recorded, so the app, the
# installers and the stores all agree:
#   pubspec.yaml  version: X.Y.Z+N   (N, the build number, goes up by one;
#                                     Android needs it to increase)
#   Cargo.toml    version = "X.Y.Z"  (shown in Settings > About)
#   Cargo.lock    the workspace crates
#
# Usage:  pwsh tools/set-version.ps1 1.2.0
# Then commit, tag vX.Y.Z and push the tag (see DEPLOYMENT.md). The Release
# workflow refuses a tag that doesn't match these files.
param([Parameter(Mandatory = $true)][string]$Version)
$ErrorActionPreference = "Stop"
if ($Version -notmatch '^\d+\.\d+\.\d+$') { throw "Use a version like 1.2.0 (got '$Version')." }
$root = Resolve-Path (Join-Path $PSScriptRoot "..")

$pubspec = Join-Path $root "pubspec.yaml"
$text = [IO.File]::ReadAllText($pubspec)
$m = [regex]::Match($text, '(?m)^version:[ \t]*(\d+\.\d+\.\d+)\+(\d+)[ \t]*(?=\r?$)')
if (-not $m.Success) { throw "No 'version: X.Y.Z+N' line in pubspec.yaml" }
$build = [int]$m.Groups[2].Value + 1
$text = $text.Remove($m.Index, $m.Length).Insert($m.Index, "version: $Version+$build")
[IO.File]::WriteAllText($pubspec, $text)

$cargo = Join-Path $root "Cargo.toml"
$text = [IO.File]::ReadAllText($cargo)
$m = [regex]::Match($text, '(?m)^version = "[^"]*"')
if (-not $m.Success) { throw "No workspace 'version = ' line in Cargo.toml" }
$text = $text.Remove($m.Index, $m.Length).Insert($m.Index, "version = `"$Version`"")
[IO.File]::WriteAllText($cargo, $text)

Push-Location $root
try {
    cargo update --workspace --offline --quiet
    if ($LASTEXITCODE -ne 0) { throw "cargo update failed" }
} finally { Pop-Location }

Write-Host "DigiClean is now version $Version (build $build)."
