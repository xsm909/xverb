#!/bin/sh
# Installs xverb. macOS and Linux.
#
#     sh install.sh                   # install for whoever is running it
#     sudo sh install.sh              # install for everyone on the machine
#     sh install.sh --archive FILE    # a particular release archive
#     sh install.sh --release         # fetch the newest release and install it
#     sh install.sh --check           # say what the newest release is, install nothing
#     sh install.sh --from DIR        # take releases from DIR instead of the network
#     sh install.sh --to DIR          # portable: into DIR, registering nothing
#     sh install.sh --uninstall       # take it out again
#
# It installs whatever it can find, in this order: an application already
# unpacked beside it, an archive beside it, the newest xverb archive in
# the Downloads folder, or — last — the newest release fetched from the release
# repository. So the two files can simply be handed to someone — they land in
# Downloads together and this script finds the other one — and it still works
# run from inside an unpacked archive.
#
# Run with nothing beside it, which is what
#
#     curl -fsSL .../install.sh | sh
#
# amounts to, it goes straight to the network: piped into `sh` there is no
# script on disk to look next to, and the current directory is somebody's
# working directory, not a place to go looking for an application.
#
# `--from DIR` makes a local directory stand in for the release repository. It
# is how the whole path is exercised without a network and without publishing
# anything: point it at a folder holding archives and their .sha256 files.
#
# Plain POSIX sh, with no dependency beyond coreutils and tar, because this is
# the one script that runs on a machine nothing has been set up on. It installs
# system-wide when it can write there and into the home directory when it
# cannot, rather than failing with a permission error and leaving the person to
# work out that sudo was the answer.

set -eu

say() { printf '%s\n' "$*"; }
die() { printf '%s\n' "$*" >&2; exit 1; }

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
action=install
portable=
archive=
unpacked=
downloaded=
from=
prefer_release=
repo=${XVERB_RELEASE_REPO:-xsm909/xverb-release}

# Piped into sh there is no script file, so there is nothing beside it and the
# only sensible source is the network. Told apart by whether $0 names a file:
# when it does not, $0 is the shell's own name.
[ -f "$0" ] || prefer_release=yes

case "$(uname -s)" in
  Darwin) system=macos ;;
  Linux)  system=linux ;;
  *) die "This installer covers macOS and Linux. On Windows use install.ps1." ;;
esac

while [ $# -gt 0 ]; do
  case "$1" in
    --uninstall|-u) action=uninstall ;;
    --release|-r) prefer_release=yes ;;
    --check) action=check ;;
    --from)
      [ $# -ge 2 ] || die "--from needs a directory."
      from=$2
      prefer_release=yes
      shift
      ;;
    --repo)
      [ $# -ge 2 ] || die "--repo needs an owner/name."
      repo=$2
      shift
      ;;
    --archive)
      [ $# -ge 2 ] || die "--archive needs a file."
      archive=$2
      shift
      ;;
    --to)
      [ $# -ge 2 ] || die "--to needs a directory."
      portable=$2
      shift
      ;;
    --help|-h)
      # Spelled out rather than read back out of this file: piped into sh there
      # is no file to read.
      cat <<'USAGE'
Installs xverb. macOS and Linux.

  sh install.sh                   install for whoever is running it
  sudo sh install.sh              install for everyone on the machine
  sh install.sh --archive FILE    a particular release archive
  sh install.sh --release         fetch the newest release and install it
  sh install.sh --check           say what the newest release is
  sh install.sh --from DIR        releases from DIR instead of the network
  sh install.sh --repo OWNER/NAME another release repository
  sh install.sh --to DIR          portable: into DIR, registering nothing
  sh install.sh --uninstall       take it out again
USAGE
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 2
      ;;
  esac
  shift
done

[ -z "$from" ] || [ -d "$from" ] || die "No such directory: $from"

# Whatever was unpacked to install from is this script's to clean up, however
# it exits — a failed install should not leave a copy of the application in the
# temporary directory.
cleanup() {
  [ -n "$unpacked" ] && [ -d "$unpacked" ] && rm -rf "$unpacked"
  [ -n "$downloaded" ] && [ -d "$downloaded" ] && rm -rf "$downloaded"
  return 0
}
trap cleanup EXIT INT TERM

# --- Finding something to install --------------------------------------

downloads_directory() {
  # XDG_DOWNLOAD_DIR when the desktop has been configured with one; the
  # user-dirs file is where GNOME and KDE record a renamed or moved folder.
  if [ -n "${XDG_DOWNLOAD_DIR:-}" ]; then
    printf '%s\n' "$XDG_DOWNLOAD_DIR"
    return 0
  fi
  config="${XDG_CONFIG_HOME:-$HOME/.config}/user-dirs.dirs"
  if [ -r "$config" ]; then
    line=$(grep '^XDG_DOWNLOAD_DIR=' "$config" 2>/dev/null | tail -1) || line=
    if [ -n "$line" ]; then
      value=$(printf '%s' "$line" | sed 's/^XDG_DOWNLOAD_DIR=//; s/^"//; s/"$//')
      # The file writes the home directory as $HOME, literally.
      value=$(printf '%s' "$value" | sed "s|^\$HOME|$HOME|")
      printf '%s\n' "$value"
      return 0
    fi
  fi
  printf '%s\n' "$HOME/Downloads"
}

# The newest matching archive, so a folder holding several releases installs
# the one most recently put there rather than whichever sorts first.
newest_archive() {
  directory=$1
  [ -d "$directory" ] || return 1
  found=$(ls -t "$directory"/xverb-*-"$system"-*.tar.gz 2>/dev/null | head -1) || found=
  [ -n "$found" ] || return 1
  printf '%s\n' "$found"
}

# --- The release repository, as a fourth source -------------------------
#
# There is no index to read and none to keep in step: a release is a set of
# files in release/, versions are 1.0.n.x, and the newest release is simply the
# largest one. Whoever publishes a release adds files; nothing else has to be
# edited, so nothing else can be forgotten.

# curl on most machines, wget on the ones that have only that. Both are told to
# fail on an HTTP error rather than saving the error page under the name of the
# thing that was asked for — a downloader that writes a 404 into an archive
# turns a missing file into a corrupt one.
have_downloader() {
  command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1
}

# Returns whatever the downloader returned. It does not `die`: this runs inside
# a command substitution, where dying would end only the subshell and leave the
# caller to invent a reason.
fetch_to_stdout() {
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$1"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO- "$1"
  else
    return 3
  fi
}

fetch_to_file() {
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$1" -o "$2"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$2" "$1"
  else
    die "Neither curl nor wget is here, so nothing can be fetched."
  fi
}

# Every archive for this system that the source holds, one name per line.
release_names() {
  if [ -n "$from" ]; then
    for path in "$from"/xverb-*-"$system"-*.tar.gz; do
      [ -f "$path" ] || continue
      basename "$path"
    done
    return 0
  fi
  # The contents endpoint lists a directory without cloning it. Read for names
  # only; anything else in the JSON is somebody else's business.
  #
  # Fetched whole first, so that a source that cannot be reached is told apart
  # from a source that holds no release. Piping straight into grep loses that
  # difference and reports a 404 repository as an empty one.
  listing=$(fetch_to_stdout "https://api.github.com/repos/$repo/contents/release") ||
    return 2
  printf '%s\n' "$listing" |
    grep -o '"name"[[:space:]]*:[[:space:]]*"[^"]*"' |
    sed 's/.*"\([^"]*\)"$/\1/' |
    grep "^xverb-.*-$system-.*\.tar\.gz$" || true
  return 0
}

# The largest version, compared number by number. Not `sort -V`, which is a GNU
# extension and not on every machine this has to run on, and not plain sort,
# which puts 1.0.10.0 before 1.0.9.0.
newest_release_name() {
  awk -F- '
    {
      split($2, part, ".")
      key = ""
      for (i = 1; i <= 4; i++) key = key sprintf("%08d", part[i] + 0)
      print key "\t" $0
    }
  ' | sort | tail -1 | cut -f2
}

sha256_of() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 "$1" | awk '{print $NF}'
  else
    return 1
  fi
}

# Fetches the newest release and returns the archive, having checked it. A
# checksum that does not match is not a warning: the file is thrown away and
# nothing on this machine is touched. Nothing is unpacked before this passes.
# Sets $release_archive. Deliberately not printed: called in a command
# substitution, every `say` here would be captured as part of the path, and a
# `die` would end only the subshell — leaving the caller to report some other
# reason for a failure that had already been explained. Both of those happened.
release_archive=
fetch_release() {
  release_archive=
  if [ -z "$from" ]; then
    have_downloader || die "Neither curl nor wget is here, so nothing can be
fetched. Download the archive yourself and pass it with --archive FILE."
  fi
  names=$(release_names) || die "Could not read the release listing at
${from:-https://github.com/$repo/tree/main/release}."
  name=$(printf '%s\n' "$names" | newest_release_name)
  [ -n "$name" ] || die "The release source holds nothing for $system.
Looked in: ${from:-https://github.com/$repo/tree/main/release}"

  downloaded=$(mktemp -d "${TMPDIR:-/tmp}/xverb-release.XXXXXX")
  if [ -n "$from" ]; then
    cp "$from/$name" "$downloaded/$name"
    [ -f "$from/$name.sha256" ] || die "No checksum beside $name in $from."
    cp "$from/$name.sha256" "$downloaded/$name.sha256"
  else
    base="https://raw.githubusercontent.com/$repo/main/release"
    say "Fetching $name"
    fetch_to_file "$base/$name" "$downloaded/$name" ||
      die "Could not download $name."
    fetch_to_file "$base/$name.sha256" "$downloaded/$name.sha256" ||
      die "$name has no checksum published beside it; refusing to install it."
  fi

  want=$(awk '{print $1; exit}' "$downloaded/$name.sha256")
  got=$(sha256_of "$downloaded/$name") ||
    die "No sha256 tool here, so $name cannot be checked. Refusing to install it."
  if [ "$want" != "$got" ]; then
    rm -rf "$downloaded"
    downloaded=
    die "$name does not match its checksum.
  published $want
  received  $got
Nothing has been installed."
  fi
  say "Checked $name against its sha256."
  release_archive=$downloaded/$name
}

# Only what is already on this machine. The release repository is reached from
# resolve_payload instead, so that its failures are reported where they happen.
find_local_archive() {
  if [ -n "$archive" ]; then
    [ -f "$archive" ] || die "No such archive: $archive"
    printf '%s\n' "$archive"
    return 0
  fi
  for directory in "$here" "$(downloads_directory)"; do
    if found=$(newest_archive "$directory"); then
      printf '%s\n' "$found"
      return 0
    fi
  done
  return 1
}

# Where the application to install actually is: beside this script if the
# archive is already unpacked, otherwise unpacked from one now.
resolve_payload() {
  payload=$here
  # Spelled as `if`, not `[ -d … ] && return`: under `set -e` the latter ends
  # the script when the directory is simply not there, which is the ordinary
  # case of installing from an archive. Asked for a release, an application
  # sitting beside this script is not the answer either — that is the copy
  # being replaced.
  if [ -z "$archive" ] && [ -z "$prefer_release" ]; then
    case "$system" in
      macos) if [ -d "$here/xverb.app" ]; then return 0; fi ;;
      linux) if [ -d "$here/xverb" ]; then return 0; fi ;;
    esac
  fi

  found=
  # An archive named outright wins over everything, including --release: asking
  # for a particular file and being given a different one is never right.
  if [ -n "$archive" ] || [ -z "$prefer_release" ]; then
    found=$(find_local_archive) || found=
  fi
  if [ -z "$found" ]; then
    # Reached in this shell, not in a substitution: a checksum that does not
    # match has to end the run saying so, not fall through to a guess about
    # Downloads.
    fetch_release
    found=$release_archive
  fi

  command -v tar >/dev/null 2>&1 || die "tar is needed to unpack $found."
  say "Unpacking $found"
  unpacked=$(mktemp -d "${TMPDIR:-/tmp}/xverb.XXXXXX")
  tar -xzf "$found" -C "$unpacked"
  payload=$unpacked
}

# --- macOS -------------------------------------------------------------

macos_install() {
  resolve_payload
  source_app="$payload/xverb.app"
  [ -d "$source_app" ] || die "That archive holds no xverb.app."

  if [ -n "$portable" ]; then
    destination=$portable
    mkdir -p "$destination"
  elif [ -w /Applications ]; then
    destination=/Applications
  else
    destination="$HOME/Applications"
    say "/Applications is not writable, so this is a personal install."
    say "Run it with sudo to install for everyone."
    mkdir -p "$destination"
  fi

  # The copy being replaced, not any xverb anywhere: a build running out
  # of a checkout is not in the way of installing one into /Applications.
  if pgrep -f "$destination/xverb.app/Contents/MacOS" >/dev/null 2>&1; then
    die "The copy in $destination is running. Quit it, then run this again."
  fi

  rm -rf "$destination/xverb.app"
  cp -R "$source_app" "$destination/"

  # An app that arrived in a downloaded archive is quarantined, and macOS
  # refuses an unsigned quarantined bundle outright rather than offering the
  # usual "open anyway". Clearing the flag on a bundle the person just chose to
  # install is the difference between it starting and it looking broken.
  xattr -dr com.apple.quarantine "$destination/xverb.app" 2>/dev/null || true

  say "Installed to $destination/xverb.app"
}

macos_uninstall() {
  removed=no
  # --to names the one place to look. Without it, both of the places an install
  # can land — and only those. An uninstall must never widen its own reach:
  # this ignored --to once and took out the copy in /Applications.
  if [ -n "$portable" ]; then
    set -- "$portable"
  else
    set -- /Applications "$HOME/Applications"
  fi
  for destination in "$@"; do
    if [ -d "$destination/xverb.app" ]; then
      rm -rf "$destination/xverb.app" && removed=yes
      say "Removed $destination/xverb.app"
    fi
  done
  [ "$removed" = yes ] || say "Nothing to remove."
  say "Settings and installed plugins are left in"
  say "  $HOME/Library/Application Support/io.github.xsm909/xverb"
}

# --- Linux -------------------------------------------------------------
#
# System-wide goes to /opt, which is where FHS puts a self-contained
# application that is not managed by the package manager. A personal install
# follows the XDG directories instead, so it needs no root and no PATH edit
# beyond ~/.local/bin, which most distributions already put on it.
#
# The program goes in ~/.local/lib and **not** in ~/.local/share/xverb,
# which is where it used to go and must never go again: that directory is the
# one Flutter hands the application as its support directory, so it holds the
# settings, the installed plugins, the saved connections, the colour schemes
# and the Python runtime it downloads. Installing there put the program on top
# of the data, and the `rm -rf` below — which is only meant to clear out the
# last version of the program — took all of it with every install. The person
# who found this had their settings wiped twice in one evening.

# Where the program went before that was noticed. Told apart from the data
# beside it by the three things the archive actually contains.
legacy="${XDG_DATA_HOME:-$HOME/.local/share}/xverb"

linux_paths() {
  if [ -n "$portable" ]; then
    prefix=$portable
  elif [ "$(id -u)" = 0 ]; then
    prefix=/opt/xverb
    bindir=/usr/local/bin
    appsdir=/usr/share/applications
    icondir=/usr/share/icons/hicolor/512x512/apps
  else
    prefix="$HOME/.local/lib/xverb"
    bindir="$HOME/.local/bin"
    appsdir="$HOME/.local/share/applications"
    icondir="$HOME/.local/share/icons/hicolor/512x512/apps"
  fi
}

# Takes the old program out of the data directory, and nothing else: the three
# entries the archive holds, and only when the executable and the engine are
# both there to say that is what they are. Everything the person owns —
# plugins, settings, python, schemes, connections — is left untouched.
linux_clear_legacy() {
  [ "$prefix" != "$legacy" ] || return 0
  [ -f "$legacy/xverb" ] || return 0
  [ -f "$legacy/lib/libflutter_linux_gtk.so" ] || return 0
  rm -rf "$legacy/xverb" "$legacy/lib" "$legacy/data"
  say "Took an older copy of the program out of $legacy,"
  say "which is where your settings and plugins live. They are untouched."
}

linux_install() {
  resolve_payload
  source_bundle="$payload/xverb"
  [ -d "$source_bundle" ] || die "That archive holds no xverb directory."
  linux_paths

  # As on macOS: only the copy about to be overwritten is in the way.
  if pgrep -f "$prefix/xverb" >/dev/null 2>&1; then
    die "The copy in $prefix is running. Close it, then run this again."
  fi

  rm -rf "$prefix"
  mkdir -p "$prefix"
  cp -R "$source_bundle/." "$prefix/"
  chmod +x "$prefix/xverb"
  linux_clear_legacy

  # A portable install is the folder and nothing else: no command on the PATH,
  # no menu entry, nothing left behind anywhere to remove later.
  if [ -n "$portable" ]; then
    say "Installed to $prefix"
    say "Run $prefix/xverb"
    return 0
  fi

  mkdir -p "$bindir" "$appsdir" "$icondir"
  ln -sf "$prefix/xverb" "$bindir/xverb"
  if [ -f "$payload/xverb.png" ]; then
    cp "$payload/xverb.png" "$icondir/xverb.png"
  fi

  cat > "$appsdir/io.github.xsm909.xverb.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Name=Xverb
GenericName=File manager
Comment=Dual-pane file manager, extended with plugins
Exec=$prefix/xverb %U
Icon=xverb
Terminal=false
Categories=Utility;FileTools;FileManager;
Keywords=file;manager;commander;xverb;
StartupWMClass=xverb
DESKTOP

  # Menus are cached, so a new entry can take a login to appear otherwise.
  command -v update-desktop-database >/dev/null 2>&1 &&
    update-desktop-database "$appsdir" >/dev/null 2>&1 || true

  say "Installed to $prefix"
  say "Command: $bindir/xverb"
  case ":$PATH:" in
    *":$bindir:"*) ;;
    *) say "Note: $bindir is not on your PATH." ;;
  esac
}

linux_uninstall() {
  linux_paths
  removed=no
  if [ -n "$portable" ]; then
    set -- "$prefix"
  else
    set -- "$prefix" \
      "$bindir/xverb" \
      "$appsdir/io.github.xsm909.xverb.desktop" \
      "$icondir/xverb.png"
  fi
  for path in "$@"; do
    if [ -e "$path" ] || [ -L "$path" ]; then
      rm -rf "$path" && removed=yes
      say "Removed $path"
    fi
  done
  [ "$removed" = yes ] || say "Nothing to remove at $prefix."
  if [ -z "$portable" ] && command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database "$appsdir" >/dev/null 2>&1 || true
  fi
  say "Settings and installed plugins are left in"
  say "  ${XDG_DATA_HOME:-$HOME/.local/share}/xverb"
}

# --- Dispatch ----------------------------------------------------------
#
# Spelled out rather than `test && install || uninstall`: that idiom runs the
# uninstall when the install fails, which is the last thing anyone wants.

if [ "$action" = check ]; then
  if [ -z "$from" ]; then
    have_downloader || die "Neither curl nor wget is here, so the release
listing cannot be read."
  fi
  names=$(release_names) || die "Could not read the release listing at
${from:-https://github.com/$repo/tree/main/release}."
  name=$(printf '%s\n' "$names" | newest_release_name)
  if [ -z "$name" ]; then
    say "No release for $system at ${from:-github.com/$repo}."
    exit 1
  fi
  version=$(printf '%s\n' "$name" | awk -F- '{print $2}')
  say "Newest release for $system: $version"
  say "  $name"
  say "  from ${from:-https://github.com/$repo/tree/main/release}"
  exit 0
fi

if [ "$action" = install ]; then
  "${system}_install"
else
  "${system}_uninstall"
fi
