#!/usr/bin/env bash
# Smoke test for the Linux bundling contract.
#
# This exists because the output layout is a contract that downstream code
# depends on, and it is easy to break invisibly: a bundle that still *builds*
# can ship a binary that cannot exec, or leak a nixpkgs wrapper full of
# /nix/store paths, or quietly go back to running everything through ld.so.
# Every assertion below corresponds to something that has actually gone wrong.
#
# Two subjects, chosen to be tiny so this stays cheap:
#   hello         via qtCliApp -- the plain path, no launcher
#   libxkbcommon  via qtApp    -- the launcher path, since its closure carries
#                                 both libxkbcommon and the xkeyboard-config
#                                 data that trigger it
#
# Usage:  tests/smoke.sh [flake-ref]     (default: the checkout, ".")
set -uo pipefail

FLAKE="${1:-.}"
# Absolutise a local flake ref before we cd into the scratch dir, or `.` would
# resolve to the scratch dir and nix would report "could not find a flake.nix".
# A ref containing ':' is a URL (github:, git+https:, path:) and is left alone.
case "$FLAKE" in
  *:*) ;;
  *)   FLAKE="$(cd "$FLAKE" 2>/dev/null && pwd)" || { echo "smoke: no such flake dir: ${1:-.}" >&2; exit 1; } ;;
esac

WORK="$(mktemp -d)"
trap 'chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT
cd "$WORK"

pass=0; fail=0
ok()   { printf '  \033[32mok\033[0m   %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; [ -n "${2:-}" ] && printf '         %s\n' "$2"; fail=$((fail+1)); }
check(){ if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1" "${3:-}"; fi; }

# The loader path this architecture's psABI mandates. Deliberately not a single
# prefix: /lib64/ld-linux-aarch64.so.1 does not exist on current Fedora or
# openSUSE, so "just use /lib64" breaks arm64.
case "$(uname -m)" in
  x86_64)  PSABI=/lib64/ld-linux-x86-64.so.2 ;;
  aarch64) PSABI=/lib/ld-linux-aarch64.so.1  ;;
  *) echo "smoke: unsupported arch $(uname -m); nothing to assert"; exit 0 ;;
esac

interp() { patchelf --print-interpreter "$1" 2>/dev/null; }
have_tag() { readelf -d "$1" 2>/dev/null | grep -q "($2)"; }

echo "== building bundles with $FLAKE =="
nix bundle --bundler "$FLAKE#qtCliApp" nixpkgs#hello        -o out-plain    || exit 1
nix bundle --bundler "$FLAKE#qtApp"    nixpkgs#libxkbcommon -o out-launcher || exit 1
P="$(readlink -f out-plain)"; L="$(readlink -f out-launcher)"

echo
echo "== plain path (guiApp = false) =="
check "bin/hello is an ELF, not a script" \
      "head -c4 '$P/bin/hello' | grep -q ELF"
check "no launcher script and no hidden companion" \
      "! ls -a '$P/bin' | grep -qE '^\.[^.]'" \
      "a companion .elf means a launcher was emitted for a headless bundle"
check "PT_INTERP is the psABI path ($PSABI)" \
      "[ \"\$(interp '$P/bin/hello')\" = '$PSABI' ]" \
      "got: $(interp "$P/bin/hello")"
check "DT_RPATH is set (bundled libs beat LD_LIBRARY_PATH)" \
      "have_tag '$P/bin/hello' RPATH"
check "DT_RUNPATH is NOT set (it loses to LD_LIBRARY_PATH)" \
      "! have_tag '$P/bin/hello' RUNPATH"

echo
echo "== launcher path (guiApp = true, xkb present) =="
check "bin/xkbcli is a launcher script" \
      "head -c2 '$L/bin/xkbcli' | grep -q '#!'"
check "the real ELF is beside it as .xkbcli.elf" \
      "head -c4 '$L/bin/.xkbcli.elf' | grep -q ELF"
check "the launcher exports XKB_CONFIG_ROOT" \
      "grep -q XKB_CONFIG_ROOT '$L/bin/xkbcli'"
check "the companion's PT_INTERP is the psABI path" \
      "[ \"\$(interp '$L/bin/.xkbcli.elf')\" = '$PSABI' ]" \
      "got: $(interp "$L/bin/.xkbcli.elf")"

echo
echo "== regressions that have actually happened =="
# nixpkgs' Qt hooks leave `.<name>-wrapped` C wrappers next to their binaries.
# Phase 1b strips them; a too-wide dotfile glob in Phase 1 shipped one.
for b in "$P" "$L"; do
  check "no nixpkgs '-wrapped' wrapper leaked into $(basename "$b")/bin" \
        "! ls -a '$b/bin' | grep -q -- '-wrapped'"
done
# The trampoline, and the LD_PRELOAD shim that existed to fake /proc/self/exe.
check "no libprocself_fix.so anywhere" \
      "! find '$P' '$L' -name 'libprocself_fix.so' | grep -q ."
check "no __BUNDLE_REAL_EXE (the shim's handshake)" \
      "! grep -rqs __BUNDLE_REAL_EXE '$L/bin'"
# A trampoline execs some OTHER program and passes the real binary to it as an
# argument -- `exec "$p" "$REAL" "$@"`, where $p is a loader found at runtime.
# Direct exec puts $REAL first: `exec "$REAL" "$@"` or `exec -a "$0" "$REAL" ...`.
# Matching that shape rather than the string "ld-linux" matters: the old
# launcher held the loader in a variable, so a grep for the name passed against
# it and proved nothing.
check "the launcher execs the real binary, not a loader with it as an argument" \
      "! grep -qE 'exec +\"\\\$[A-Za-z_]+\" +\"\\\$REAL\"' '$L/bin/xkbcli'" \
      "a launcher that hands the program to ld.so makes /proc/self/exe lie"
check "the launcher has no runtime loader-path probe" \
      "! grep -qE '\\\$INTERP_NAME' '$L/bin/xkbcli'" \
      "probing for the loader at runtime is what the psABI path replaced"

echo
echo "== runs on other distros =="
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  for img in ubuntu:latest fedora:latest; do
    for pair in "$P:hello" "$L:xkbcli --version"; do
      dir="${pair%%:*}"; cmd="${pair#*:}"
      if docker run --rm -v "$dir:/b:ro" "$img" sh -c "/b/bin/$cmd" >/dev/null 2>&1; then
        ok "$img: /b/bin/${cmd%% *}"
      else
        bad "$img: /b/bin/${cmd%% *}" "$(docker run --rm -v "$dir:/b:ro" "$img" sh -c "/b/bin/$cmd" 2>&1 | tail -1)"
      fi
    done
  done
else
  echo "  -- docker unavailable, skipping the cross-distro run"
  echo "     (the layout assertions above still ran; portability did not)"
fi

echo
echo "== $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
