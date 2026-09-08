<#
.SYNOPSIS
    Installs xverb.

.DESCRIPTION
    It installs whatever it can find, in this order: an application already
    unpacked beside it, a release archive beside it, the newest xverb
    archive in the Downloads folder, or — last — the newest release fetched
    from the release repository. So the two files can simply be handed to
    someone — they land in Downloads together and this script finds the other
    one — and it still works run from inside an unpacked archive.

    Piped into PowerShell, which is what

        irm https://.../install.ps1 | iex

    amounts to, it goes straight to the release repository: there is no script
    on disk to look next to, and the current directory is somebody's working
    directory rather than a place to go looking for an application.

    It installs for the current user only, into %LOCALAPPDATA%\Programs\xverb,
    and needs no elevation at any point. There is deliberately no all-users
    install: xverb updates itself in place, and putting a new version in place
    is a rename inside the folder the installed copy sits in. Under Program
    Files that rename needs administrator rights the running application does
    not have — so every update would fail with an access error about a
    directory nobody had mentioned, which is exactly what it did. A program
    that can replace itself has to live where it may write.

    It adds a Start menu shortcut and registers the application in Apps &
    features for this user, so Windows can uninstall it the ordinary way.

.PARAMETER Uninstall
    Removes an installation made by this script. Settings and installed plugins
    are left alone.

.PARAMETER Path
    Install somewhere other than the default. A portable install: no shortcut,
    no registry entry, nothing outside the folder.

.PARAMETER Archive
    Install from this archive rather than whichever one it would have found.

.PARAMETER Release
    Fetch the newest release and install that, ignoring anything lying about
    locally.

.PARAMETER Check
    Say what the newest release is and install nothing.

.PARAMETER From
    Take releases from this directory instead of the network. It is how the
    whole path is exercised without a network and without publishing anything:
    point it at a folder holding archives and their .sha256 files.

.PARAMETER Repo
    Another release repository, as owner/name.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File install.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File install.ps1 -Uninstall
#>

[CmdletBinding()]
param(
    [switch]$Uninstall,
    [string]$Path,
    [string]$Archive,
    [switch]$Release,
    [switch]$Check,
    [string]$From,
    [string]$Repo
)

$ErrorActionPreference = 'Stop'

if (-not $Repo) {
    $Repo = if ($env:XVERB_RELEASE_REPO) { $env:XVERB_RELEASE_REPO }
            else { 'xsm909/xverb-release' }
}

# Windows PowerShell 5.1 still defaults to TLS 1.0 on some machines, and
# github.com refuses it — which shows up as a connection failure rather than
# anything mentioning protocols.
try {
    [Net.ServicePointManager]::SecurityProtocol =
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch {
    # An edition that does not have this class does not need it either.
}

# $PSScriptRoot and $PSCommandPath, not $MyInvocation: inside a function the
# latter describes the function rather than the script, which is how an
# installer ends up copying nothing and reporting success.
$here = $PSScriptRoot
$scriptPath = $PSCommandPath
# Where the application being installed is read from, and the temporary copy to
# clear away afterwards if one was made. Both set by Resolve-Payload.
$payload = $PSScriptRoot
$unpacked = $null
$downloaded = $null
$appName = 'xverb'
$displayName = 'Xverb'
$registryKey = 'xverb'

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]$identity
    $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

$isAdmin = Test-Administrator
$portable = [bool]$Path

# Piped into PowerShell there is no script file, so there is nothing beside it
# and the only sensible source is the release repository.
$preferRelease = [bool]$Release -or [bool]$From -or (-not $PSCommandPath)

# Always this user, never the machine. See the note in .DESCRIPTION: an
# application that replaces itself must be installed where it may write, and
# elevation here would buy a folder every later update is locked out of.
if (-not $Path) {
    $Path = Join-Path $env:LOCALAPPDATA "Programs\$appName"
}

$uninstallKey = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\$registryKey"
$startMenu = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
$shortcut = Join-Path $startMenu "$displayName.lnk"

# Where an older version of this script installed when it was run elevated.
# Kept only to find such a copy and say so — nothing is ever installed here.
$machineKey = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\$registryKey"
$machinePath = Join-Path $env:ProgramFiles $appName
$machineShortcut = Join-Path (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs') "$displayName.lnk"

function Remove-MachineWideInstall {
    <#
        An earlier version of this script installed to Program Files when it
        was run as an administrator. Such a copy is not a copy of the thing
        being installed now — it is a second application with its own shortcut
        and its own entry in Apps & features, and Windows will happily start
        whichever of the two the person clicks. So it is dealt with rather than
        ignored: removed when this run has the rights, and named plainly when
        it does not. Nothing is ever installed there again.
    #>
    $registered = Test-Path $machineKey
    if (-not $registered -and -not (Test-Path $machinePath)) { return }

    if (-not $isAdmin) {
        Write-Host ""
        Write-Host "An all-users copy is still in $machinePath."
        Write-Host "An older version of this script put it there, and a copy in Program Files"
        Write-Host "cannot update itself. Until it goes there are two Xverb entries in the"
        Write-Host "Start menu and two in Apps & features. Removing it needs an administrator:"
        Write-Host "  powershell -ExecutionPolicy Bypass -File `"$(Join-Path $machinePath 'install.ps1')`" -Uninstall"
        Write-Host ""
        return
    }

    Write-Host "Removing the all-users copy in $machinePath"
    if (Test-Path $machinePath) {
        Remove-Item -Recurse -Force $machinePath -ErrorAction SilentlyContinue
    }
    if (Test-Path $machineShortcut) { Remove-Item $machineShortcut -Force }
    if ($registered) { Remove-Item -Path $machineKey -Recurse -Force }
    if (Test-Path $machinePath) {
        Write-Host "$machinePath is still there — something in it is in use."
    }
}

function Stop-IfRunning {
    # Only the copy about to be replaced counts. A build running out of a
    # checkout, or a portable copy elsewhere, is not in the way of this one.
    $running = Get-Process -Name $appName -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -and $_.Path.StartsWith($Path, 'OrdinalIgnoreCase') }
    if ($running) {
        throw "The copy in $Path is running. Close it, then run this again."
    }
}

function Read-Version {
    $file = Join-Path $payload 'VERSION'
    if (Test-Path $file) { (Get-Content $file -TotalCount 1).Trim() } else { '1.0.0' }
}

function Get-DownloadsDirectory {
    # The Known Folder entry, because Downloads can be moved or renamed and
    # %USERPROFILE%\Downloads would then be a folder nobody uses.
    $known = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders'
    $guid = '{374DE290-123F-4565-9164-39C4925E467B}'
    $recorded = (Get-ItemProperty -Path $known -Name $guid -ErrorAction SilentlyContinue).$guid
    if ($recorded -and (Test-Path $recorded)) { return $recorded }
    Join-Path $env:USERPROFILE 'Downloads'
}

# --- The release repository, as a fourth source ---------------------------
#
# There is no index to read and none to keep in step: a release is a set of
# files in release/, versions are 1.0.n.x, and the newest release is simply the
# largest one. Whoever publishes a release adds files; nothing else has to be
# edited, so nothing else can be forgotten.

function Get-ReleaseNames {
    if ($From) {
        if (-not (Test-Path $From)) { throw "No such directory: $From" }
        return @(Get-ChildItem -Path $From -Filter 'xverb-*-windows-*.zip' -File |
            ForEach-Object { $_.Name })
    }
    # The contents endpoint lists a directory without cloning it. A failure to
    # reach it is deliberately not caught here: a repository that cannot be
    # read must not be reported as a repository holding no release.
    $listing = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/contents/release" -UseBasicParsing
    return @($listing | ForEach-Object { $_.name } |
        Where-Object { $_ -like 'xverb-*-windows-*.zip' })
}

# The largest version, compared number by number rather than as text, so that
# 1.0.10.0 comes after 1.0.9.0 instead of before it.
function Get-NewestReleaseName {
    param([string[]]$Names)
    if (-not $Names -or $Names.Count -eq 0) { return $null }
    return ($Names | Sort-Object -Property @{ Expression = {
        if ($_ -match '^xverb-(\d+(?:\.\d+){0,3})-') { [version]$Matches[1] }
        else { [version]'0.0.0.0' }
    } } | Select-Object -Last 1)
}

function Get-ReleaseVersion {
    param([string]$Name)
    if ($Name -match '^xverb-(\d+(?:\.\d+){0,3})-') { return $Matches[1] }
    return $null
}

# Fetches the newest release and returns the archive, having checked it. A
# checksum that does not match is not a warning: the file is thrown away and
# nothing on this machine is touched. Nothing is unpacked before this passes.
function Get-Release {
    $names = Get-ReleaseNames
    $name = Get-NewestReleaseName -Names $names
    if (-not $name) {
        $where = if ($From) { $From } else { "https://github.com/$Repo/tree/main/release" }
        throw "The release source holds nothing for windows. Looked in: $where"
    }

    $downloaded = Join-Path ([IO.Path]::GetTempPath()) ("xverb-release-" + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $downloaded | Out-Null
    $script:downloaded = $downloaded
    $archivePath = Join-Path $downloaded $name
    $sumPath = "$archivePath.sha256"

    if ($From) {
        Copy-Item -Path (Join-Path $From $name) -Destination $archivePath -Force
        $sourceSum = Join-Path $From "$name.sha256"
        if (-not (Test-Path $sourceSum)) { throw "No checksum beside $name in $From." }
        Copy-Item -Path $sourceSum -Destination $sumPath -Force
    } else {
        $base = "https://raw.githubusercontent.com/$Repo/main/release"
        Write-Host "Fetching $name"
        Invoke-WebRequest -Uri "$base/$name" -OutFile $archivePath -UseBasicParsing
        try {
            Invoke-WebRequest -Uri "$base/$name.sha256" -OutFile $sumPath -UseBasicParsing
        } catch {
            throw "$name has no checksum published beside it; refusing to install it."
        }
    }

    $want = ((Get-Content $sumPath -TotalCount 1) -split '\s+')[0]
    $got = (Get-FileHash -Path $archivePath -Algorithm SHA256).Hash
    if ($want -ne $got) {
        Remove-Item -Recurse -Force $downloaded -ErrorAction SilentlyContinue
        $script:downloaded = $null
        throw "$name does not match its checksum.`n  published $want`n  received  $got`nNothing has been installed."
    }
    Write-Host "Checked $name against its sha256."
    return $archivePath
}

function Find-Archive {
    if ($Archive) {
        if (-not (Test-Path $Archive)) { throw "No such archive: $Archive" }
        return (Resolve-Path $Archive).Path
    }
    # Newest first, so a folder holding several releases installs the one most
    # recently put there rather than whichever sorts first.
    foreach ($directory in @($here, (Get-DownloadsDirectory))) {
        if (-not $directory -or -not (Test-Path $directory)) { continue }
        $found = Get-ChildItem -Path $directory -Filter 'xverb-*-windows-*.zip' -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1
        if ($found) { return $found.FullName }
    }
    return $null
}

# Where the application to install actually is: beside this script if the
# archive is already unpacked, otherwise unpacked from one now.
function Resolve-Payload {
    # Asked for a release, an application sitting beside this script is not the
    # answer either — that is the copy being replaced.
    if (-not $Archive -and -not $preferRelease -and $here -and (Test-Path (Join-Path $here $appName))) {
        $script:payload = $here
        return
    }

    $found = $null
    # An archive named outright wins over everything, including -Release:
    # asking for a particular file and being given a different one is never
    # right.
    if ($Archive -or -not $preferRelease) { $found = Find-Archive }
    if (-not $found) { $found = Get-Release }

    Write-Host "Unpacking $found"
    $script:unpacked = Join-Path ([IO.Path]::GetTempPath()) ("xverb-" + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $script:unpacked | Out-Null
    # Unblock first: Expand-Archive refuses some marked archives outright.
    Unblock-File -Path $found -ErrorAction SilentlyContinue
    Expand-Archive -Path $found -DestinationPath $script:unpacked -Force
    $script:payload = $script:unpacked
}

function Install-App {
    Resolve-Payload
    $source = Join-Path $payload $appName
    if (-not (Test-Path $source)) {
        throw "That archive holds no $appName folder."
    }
    Stop-IfRunning

    Write-Host "Installing to $Path"
    if (Test-Path $Path) { Remove-Item -Recurse -Force $Path }
    New-Item -ItemType Directory -Force -Path $Path | Out-Null
    Copy-Item -Path (Join-Path $source '*') -Destination $Path -Recurse -Force

    # A file that arrived in a downloaded archive carries a zone marker, and
    # Windows treats a marked executable as untrusted every time it is started.
    Get-ChildItem -Path $Path -Recurse -File |
        Unblock-File -ErrorAction SilentlyContinue

    # The installer itself goes with it: an uninstall entry has to point at a
    # script that will still be there when it is used.
    if ($scriptPath -and ($scriptPath -ne (Join-Path $Path 'install.ps1'))) {
        Copy-Item -Path $scriptPath -Destination (Join-Path $Path 'install.ps1') -Force
    }
    Copy-Item -Path (Join-Path $payload 'VERSION') -Destination $Path -Force -ErrorAction SilentlyContinue

    if ($portable) {
        Write-Host "Portable install: no shortcut and no registry entry."
        Write-Host "Run $(Join-Path $Path "$appName.exe")"
        return
    }

    New-Item -ItemType Directory -Force -Path $startMenu | Out-Null
    $shell = New-Object -ComObject WScript.Shell
    $link = $shell.CreateShortcut($shortcut)
    $link.TargetPath = Join-Path $Path "$appName.exe"
    $link.WorkingDirectory = $Path
    $link.Description = 'Dual-pane file manager, extended with plugins'
    $link.Save()

    $version = Read-Version
    New-Item -Path $uninstallKey -Force | Out-Null
    $entries = @{
        DisplayName     = $displayName
        DisplayVersion  = $version
        Publisher       = 'xsm909'
        InstallLocation = $Path
        DisplayIcon     = Join-Path $Path "$appName.exe"
        URLInfoAbout    = 'https://github.com/xsm909/xverb'
        NoModify        = 1
        NoRepair        = 1
        UninstallString = "powershell -ExecutionPolicy Bypass -File `"$(Join-Path $Path 'install.ps1')`" -Uninstall"
    }
    foreach ($entry in $entries.GetEnumerator()) {
        New-ItemProperty -Path $uninstallKey -Name $entry.Key -Value $entry.Value -Force | Out-Null
    }

    Write-Host "Installed $displayName $version for $env:USERNAME"
    Write-Host "Start menu: $shortcut"

    # Last, and not first: this script may be the copy *inside* the folder it
    # is about to remove — the uninstall entry of an older all-users install
    # points straight at it — and the payload is often read from beside it.
    # Nothing of the old copy is touched until the new one is installed.
    Remove-MachineWideInstall

    if ($isAdmin) {
        # Same-user elevation keeps the profile, so this is usually harmless —
        # but it is worth saying where it went, because "Run as administrator"
        # with somebody else's credentials installs into their profile and not
        # into the one whose Start menu the person is looking at.
        Write-Host "Elevation is not needed here: this went into $($env:USERNAME)'s own folder."
    }
}

function Uninstall-App {
    # Started from inside the all-users copy: the Apps & features entry of an
    # older install points straight at that script, so that is the copy being
    # asked about. A personal install standing beside it is a different
    # installation and none of this run's business.
    if (-not $portable -and $here -and
        ($here.TrimEnd('\') -ieq $machinePath.TrimEnd('\'))) {
        Remove-MachineWideInstall
        Write-Host "Settings and installed plugins are left in $env:APPDATA\io.github.xsm909\xverb"
        return
    }

    Stop-IfRunning
    $removed = $false

    # -Path names the one folder to remove, and nothing else: a portable copy
    # knows nothing about the registered install and must not reach for it.
    # Otherwise, where it actually went if the registry remembers — the default
    # may not be where this copy was installed.
    $recorded = if ($portable) { $null } else {
        (Get-ItemProperty -Path $uninstallKey -Name InstallLocation -ErrorAction SilentlyContinue).InstallLocation
    }
    $target = if ($recorded) { $recorded } else { $Path }

    if (Test-Path $target) {
        # The script being run may be the copy inside the folder, so the folder
        # cannot simply be deleted from under it on every Windows. Everything
        # else goes first, then the folder, and a leftover install.ps1 is
        # reported rather than pretended away.
        Get-ChildItem -Path $target -Force |
            Where-Object { $_.Name -ne 'install.ps1' } |
            Remove-Item -Recurse -Force
        Remove-Item -Path $target -Recurse -Force -ErrorAction SilentlyContinue
        $removed = $true
        if (Test-Path $target) {
            Write-Host "Removed everything in $target; the folder itself holds this script and can go once it stops running."
        } else {
            Write-Host "Removed $target"
        }
    }
    if (-not $portable) {
        if (Test-Path $shortcut) { Remove-Item $shortcut -Force; Write-Host "Removed $shortcut"; $removed = $true }
        if (Test-Path $uninstallKey) { Remove-Item $uninstallKey -Recurse -Force; $removed = $true }
    }

    if (-not $portable -and
        ((Test-Path $machineKey) -or (Test-Path $machinePath))) {
        Remove-MachineWideInstall
        $removed = $true
    }

    if (-not $removed) { Write-Host "Nothing to remove." }
    Write-Host "Settings and installed plugins are left in $env:APPDATA\io.github.xsm909\xverb"
}

try {
    if ($Check) {
        $names = Get-ReleaseNames
        $name = Get-NewestReleaseName -Names $names
        $where = if ($From) { $From } else { "https://github.com/$Repo/tree/main/release" }
        if (-not $name) {
            Write-Host "No release for windows at $where."
            exit 1
        }
        Write-Host "Newest release for windows: $(Get-ReleaseVersion -Name $name)"
        Write-Host "  $name"
        Write-Host "  from $where"
    }
    elseif ($Uninstall) { Uninstall-App }
    else { Install-App }
} finally {
    # Whatever was unpacked to install from is this script's to clean up,
    # however it exits — a failed install should not leave a copy of the
    # application in the temporary directory.
    if ($unpacked -and (Test-Path $unpacked)) {
        Remove-Item -Recurse -Force $unpacked -ErrorAction SilentlyContinue
    }
    if ($downloaded -and (Test-Path $downloaded)) {
        Remove-Item -Recurse -Force $downloaded -ErrorAction SilentlyContinue
    }
}
