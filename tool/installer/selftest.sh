#!/bin/sh
# Exercises install.sh against a release repository that does not exist.
#
#     sh tool/installer/selftest.sh
#
# The point is the fourth source — fetching a release, checking it, and
# refusing when the check fails — tried without a network and without
# publishing anything. A directory stands in for the release repository, which
# is what `--from` is for.
#
# The payload is synthetic: a few bytes shaped like an installed application,
# not a real build. A test that needs the project built first is a test nobody
# runs.

set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
installer="$here/install.sh"
[ -f "$installer" ] || { echo "No install.sh beside this script." >&2; exit 1; }

case "$(uname -s)" in
  Darwin) system=macos; arch=arm64 ;;
  Linux)  system=linux; arch=x64 ;;
  *) echo "This self-test covers macOS and Linux." >&2; exit 1 ;;
esac

work=$(mktemp -d "${TMPDIR:-/tmp}/xverb-selftest.XXXXXX")
trap 'rm -rf "$work"' EXIT INT TERM

passed=0
failed=0

ok()   { passed=$((passed + 1)); printf '  ok    %s\n' "$1"; }
bad()  { failed=$((failed + 1)); printf '  FAIL  %s\n' "$1"; [ -z "${2:-}" ] || printf '        %s\n' "$2"; }

# --- a payload shaped like an install, without a build ------------------

make_payload() {
  root=$1
  rm -rf "$root"
  if [ "$system" = macos ]; then
    mkdir -p "$root/xverb.app/Contents/MacOS"
    printf '#!/bin/sh\necho stub\n' > "$root/xverb.app/Contents/MacOS/xverb"
    chmod +x "$root/xverb.app/Contents/MacOS/xverb"
    printf '%s\n' '<plist/>' > "$root/xverb.app/Contents/Info.plist"
  else
    mkdir -p "$root/xverb/lib" "$root/xverb/data"
    printf '#!/bin/sh\necho stub\n' > "$root/xverb/xverb"
    chmod +x "$root/xverb/xverb"
    : > "$root/xverb/lib/libflutter_linux_gtk.so"
  fi
}

# One archive named for a version, with the checksum beside it.
publish() {
  directory=$1
  version=$2
  sys=${3:-$system}
  ar=${4:-$arch}
  name="xverb-$version-$sys-$ar.tar.gz"
  stage="$work/stage"
  make_payload "$stage"
  printf '%s\n%s\n' "$version" "$sys" > "$stage/VERSION"
  mkdir -p "$directory"
  (cd "$stage" && tar -czf "$directory/$name" .)
  sum=$(sha256_of "$directory/$name")
  printf '%s  %s\n' "$sum" "$name" > "$directory/$name.sha256"
  printf '%s\n' "$name"
}

sha256_of() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    echo "No sha256 tool here." >&2; exit 1
  fi
}

installed() {
  if [ "$system" = macos ]; then
    [ -d "$1/xverb.app" ]
  else
    [ -x "$1/xverb" ]
  fi
}

# Runs the installer, keeping output and status. Never lets a failure end the
# self-test: a case that is *meant* to fail is most of what is tested here.
run() {
  set +e
  out=$(sh "$installer" "$@" 2>&1)
  rc=$?
  set -e
}

# --- the release directory nothing was ever published to ----------------

release="$work/release"
mkdir -p "$release"
publish "$release" 1.0.1.0  >/dev/null
publish "$release" 1.0.2.0  >/dev/null
publish "$release" 1.0.10.0 >/dev/null
# Another system's archive, which must be ignored however new it looks.
other=linux; [ "$system" = linux ] && other=macos
publish "$release" 1.0.99.0 "$other" x64 >/dev/null

echo "install.sh self-test — $system/$arch"
echo

# 1. the newest is the largest number, not the longest string
run --check --from "$release"
case "$out" in
  *1.0.10.0*) ok "--check names 1.0.10.0, so ten sorts above two" ;;
  *) bad "--check picked the wrong release" "$out" ;;
esac
case "$out" in
  *1.0.99.0*) bad "--check offered the other platform's archive" "$out" ;;
  *) ok "the other platform's archive is ignored" ;;
esac

# 2. a good release installs
target="$work/target"
run --from "$release" --to "$target"
if [ $rc -eq 0 ] && installed "$target"; then
  ok "a release with a matching checksum installs"
else
  bad "installing a good release failed (rc=$rc)" "$out"
fi

# 3. a checksum that does not match stops everything
badsum="$work/badsum"
cp -R "$release" "$badsum"
newest="xverb-1.0.10.0-$system-$arch.tar.gz"
printf '%064d  %s\n' 0 "$newest" > "$badsum/$newest.sha256"
run --from "$badsum" --to "$target"
if [ $rc -ne 0 ] && installed "$target"; then
  case "$out" in
    *checksum*) ok "a wrong checksum refuses, and says so" ;;
    *) bad "refused, but not for a reason anyone can act on" "$out" ;;
  esac
else
  bad "a wrong checksum did not stop the install (rc=$rc)" "$out"
fi

# 4. a truncated download is the same thing, caught the same way
trunc="$work/trunc"
cp -R "$release" "$trunc"
# Half of it, measured — not a fixed number of blocks. A fixed count larger
# than the file copies the whole thing and truncates nothing, and the test then
# passes for the wrong reason. It did.
size=$(wc -c < "$release/$newest")
dd if="$release/$newest" of="$trunc/$newest" bs=1 count=$((size / 2)) 2>/dev/null
run --from "$trunc" --to "$target"
if [ $rc -ne 0 ] && installed "$target"; then
  ok "a truncated archive refuses, installed copy untouched"
else
  bad "a truncated archive was installed anyway (rc=$rc)" "$out"
fi

# 5 and 6. nothing to offer, and nowhere to look, must not read alike
empty="$work/empty"; mkdir -p "$empty"
run --from "$empty" --to "$target"
case "$out" in
  *"holds nothing"*) ok "an empty source says it holds nothing" ;;
  *) bad "an empty source reported something else" "$out" ;;
esac
run --from "$work/nowhere" --to "$target"
case "$out" in
  *"No such directory"*) ok "a missing source is told apart from an empty one" ;;
  *) bad "a missing source reported something else" "$out" ;;
esac

# 7. the local sources still come first, and still work
beside="$work/beside"
mkdir -p "$beside"
cp "$installer" "$beside/install.sh"
cp "$release/xverb-1.0.1.0-$system-$arch.tar.gz" "$beside/"
target2="$work/target2"
set +e
out=$(sh "$beside/install.sh" --to "$target2" 2>&1); rc=$?
set -e
if [ $rc -eq 0 ] && installed "$target2"; then
  case "$out" in
    *1.0.1.0*) ok "an archive beside the script is preferred to the network" ;;
    *) bad "installed, but not from the archive beside it" "$out" ;;
  esac
else
  bad "the archive beside the script no longer installs (rc=$rc)" "$out"
fi

# 8. --archive still names one exactly
target3="$work/target3"
run --archive "$release/xverb-1.0.2.0-$system-$arch.tar.gz" --to "$target3"
if [ $rc -eq 0 ] && installed "$target3"; then
  ok "--archive still installs the file it names"
else
  bad "--archive stopped working (rc=$rc)" "$out"
fi

# 9. --release ignores what is lying about locally
run --release --from "$release" --to "$target3"
case "$out" in
  *1.0.10.0*) ok "--release takes the release, not what is beside the script" ;;
  *) bad "--release did not go to the release source" "$out" ;;
esac

# 10. an archive named outright beats --release
run --release --from "$release" --archive "$release/xverb-1.0.1.0-$system-$arch.tar.gz" --to "$work/target4"
case "$out" in
  *1.0.1.0*) ok "--archive wins over --release" ;;
  *) bad "--release overrode an archive that was named outright" "$out" ;;
esac

# 11. an application already unpacked beside the script — the first source,
# and the one `package.dart --install` goes through, so a change that breaks it
# breaks every build on the machine that made it.
unpackedbeside="$work/unpacked"
make_payload "$unpackedbeside"
cp "$installer" "$unpackedbeside/install.sh"
printf '9.9.9.9\n%s\n' "$system" > "$unpackedbeside/VERSION"
target5="$work/target5"
set +e
out=$(sh "$unpackedbeside/install.sh" --to "$target5" 2>&1); rc=$?
set -e
if [ $rc -eq 0 ] && installed "$target5"; then
  case "$out" in
    *Unpacking*) bad "unpacked an archive when the application was right there" "$out" ;;
    *) ok "an application unpacked beside the script installs without an archive" ;;
  esac
else
  bad "the unpacked-beside source stopped working (rc=$rc)" "$out"
fi

echo
printf '%d passed, %d failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
