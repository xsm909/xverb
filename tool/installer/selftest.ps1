<#
.SYNOPSIS
    Exercises install.ps1 against a release repository that does not exist.

.DESCRIPTION
    The point is the fourth source — fetching a release, checking it, and
    refusing when the check fails — tried without a network and without
    publishing anything. A directory stands in for the release repository,
    which is what -From is for.

    The payload is synthetic: a few bytes shaped like an installed application,
    not a real build. A test that needs the project built first is a test
    nobody runs.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tool\installer\selftest.ps1
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$here = $PSScriptRoot
$installer = Join-Path $here 'install.ps1'
if (-not (Test-Path $installer)) { throw "No install.ps1 beside this script." }

$work = Join-Path ([IO.Path]::GetTempPath()) ("xverb-selftest-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $work | Out-Null

$passed = 0
$failed = 0
function ok   { param($m) $script:passed++; Write-Host "  ok    $m" }
function bad  { param($m, $d) $script:failed++; Write-Host "  FAIL  $m"; if ($d) { Write-Host "        $d" } }

# --- a payload shaped like an install, without a build --------------------

function New-Payload {
    param([string]$Root)
    if (Test-Path $Root) { Remove-Item -Recurse -Force $Root }
    New-Item -ItemType Directory -Force -Path (Join-Path $Root 'xverb\data') | Out-Null
    Set-Content -Path (Join-Path $Root 'xverb\xverb.exe') -Value 'stub' -Encoding Ascii
    Set-Content -Path (Join-Path $Root 'xverb\data\anything') -Value 'stub' -Encoding Ascii
}

# One archive named for a version, with the checksum beside it.
function Publish {
    param([string]$Directory, [string]$Version, [string]$System = 'windows', [string]$Arch = 'x64')
    $name = "xverb-$Version-$System-$Arch.zip"
    $stage = Join-Path $work 'stage'
    New-Payload -Root $stage
    Set-Content -Path (Join-Path $stage 'VERSION') -Value "$Version`n$System" -Encoding Ascii
    New-Item -ItemType Directory -Force -Path $Directory | Out-Null
    $archive = Join-Path $Directory $name
    if (Test-Path $archive) { Remove-Item -Force $archive }
    Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $archive
    $sum = (Get-FileHash -Path $archive -Algorithm SHA256).Hash
    Set-Content -Path "$archive.sha256" -Value "$sum  $name" -Encoding Ascii
    return $name
}

function Installed { param([string]$Target) Test-Path (Join-Path $Target 'xverb.exe') }

# Runs the installer in its own process, the way anyone actually runs it, and
# keeps both what it said and what it returned. A case that is meant to fail is
# most of what is tested here, so a failure must never end the self-test.
function Run {
    $arguments = @('-ExecutionPolicy', 'Bypass', '-File', $installer) + $args
    $script:out = (& powershell @arguments 2>&1 | Out-String)
    $script:rc = $LASTEXITCODE
}

# --- the release directory nothing was ever published to ------------------

$release = Join-Path $work 'release'
New-Item -ItemType Directory -Force -Path $release | Out-Null
Publish -Directory $release -Version '1.0.1.0'  | Out-Null
Publish -Directory $release -Version '1.0.2.0'  | Out-Null
Publish -Directory $release -Version '1.0.10.0' | Out-Null
# Another platform's archive, which must be ignored however new it looks.
Publish -Directory $release -Version '1.0.99.0' -System 'macos' -Arch 'arm64' | Out-Null

Write-Host "install.ps1 self-test — windows/x64"
Write-Host ""

# 1. the newest is the largest number, not the longest string
Run -Check -From $release
if ($out -match '1\.0\.10\.0') { ok "-Check names 1.0.10.0, so ten sorts above two" }
else { bad "-Check picked the wrong release" $out }
if ($out -match '1\.0\.99\.0') { bad "-Check offered the other platform's archive" $out }
else { ok "the other platform's archive is ignored" }

# 2. a good release installs
$target = Join-Path $work 'target'
Run -From $release -Path $target
if ($rc -eq 0 -and (Installed $target)) { ok "a release with a matching checksum installs" }
else { bad "installing a good release failed (rc=$rc)" $out }

# 3. a checksum that does not match stops everything
$badsum = Join-Path $work 'badsum'
Copy-Item -Recurse -Force $release $badsum
$newest = 'xverb-1.0.10.0-windows-x64.zip'
Set-Content -Path (Join-Path $badsum "$newest.sha256") -Value ("0" * 64 + "  $newest") -Encoding Ascii
Run -From $badsum -Path $target
if ($rc -ne 0 -and (Installed $target)) {
    if ($out -match 'checksum') { ok "a wrong checksum refuses, and says so" }
    else { bad "refused, but not for a reason anyone can act on" $out }
} else { bad "a wrong checksum did not stop the install (rc=$rc)" $out }

# 4. a truncated download is the same thing, caught the same way
$trunc = Join-Path $work 'trunc'
Copy-Item -Recurse -Force $release $trunc
$whole = [IO.File]::ReadAllBytes((Join-Path $release $newest))
[IO.File]::WriteAllBytes((Join-Path $trunc $newest), $whole[0..([int]($whole.Length / 2))])
Run -From $trunc -Path $target
if ($rc -ne 0 -and (Installed $target)) { ok "a truncated archive refuses, installed copy untouched" }
else { bad "a truncated archive was installed anyway (rc=$rc)" $out }

# 5 and 6. nothing to offer, and nowhere to look, must not read alike
$empty = Join-Path $work 'empty'
New-Item -ItemType Directory -Force -Path $empty | Out-Null
Run -From $empty -Path $target
if ($out -match 'holds nothing') { ok "an empty source says it holds nothing" }
else { bad "an empty source reported something else" $out }
Run -From (Join-Path $work 'nowhere') -Path $target
if ($out -match 'No such directory') { ok "a missing source is told apart from an empty one" }
else { bad "a missing source reported something else" $out }

# 7. the local sources still come first, and still work
$beside = Join-Path $work 'beside'
New-Item -ItemType Directory -Force -Path $beside | Out-Null
Copy-Item $installer (Join-Path $beside 'install.ps1')
Copy-Item (Join-Path $release 'xverb-1.0.1.0-windows-x64.zip') $beside
$target2 = Join-Path $work 'target2'
$out = (& powershell -ExecutionPolicy Bypass -File (Join-Path $beside 'install.ps1') -Path $target2 2>&1 | Out-String)
$rc = $LASTEXITCODE
if ($rc -eq 0 -and (Installed $target2) -and $out -match '1\.0\.1\.0') {
    ok "an archive beside the script is preferred to the network"
} else { bad "the archive beside the script no longer installs (rc=$rc)" $out }

# 8. -Archive still names one exactly
$target3 = Join-Path $work 'target3'
Run -Archive (Join-Path $release 'xverb-1.0.2.0-windows-x64.zip') -Path $target3
if ($rc -eq 0 -and (Installed $target3)) { ok "-Archive still installs the file it names" }
else { bad "-Archive stopped working (rc=$rc)" $out }

# 9. -Release ignores what is lying about locally
Run -Release -From $release -Path $target3
if ($out -match '1\.0\.10\.0') { ok "-Release takes the release, not what is beside the script" }
else { bad "-Release did not go to the release source" $out }

# 10. an archive named outright beats -Release
Run -Release -From $release -Archive (Join-Path $release 'xverb-1.0.1.0-windows-x64.zip') -Path (Join-Path $work 'target4')
if ($out -match '1\.0\.1\.0') { ok "-Archive wins over -Release" }
else { bad "-Release overrode an archive that was named outright" $out }

Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "$passed passed, $failed failed"
if ($failed -ne 0) { exit 1 }
