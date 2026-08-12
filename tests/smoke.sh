#!/usr/bin/env bash
# Smoke test for the bundling contract.
#
# This exists because the output layout is a contract that downstream code
# depends on, and it is easy to break invisibly: a bundle that still *builds*
# can ship a binary that cannot exec, or leak a nixpkgs wrapper full of
# /nix/store paths, or quietly go back to running everything through ld.so.
# Every assertion below corresponds to something that has actually gone wrong.
#
# Three sections. The extraDirs contract runs everywhere, because the bug it
# guards was platform-independent; the Windows/PE hostLibs contract runs on
# x86_64-linux only and says so out loud when it does not; everything after the
# arch gate is ELF, and a non-Linux host stops there rather than pretending it
# checked.
#
# Two subjects for the ELF section, chosen to be tiny so this stays cheap:
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

# == the extraDirs contract ==================================================
#
# First, and above the arch gate, because none of it is Linux-specific: the bug
# it guards (see tests/extra-dirs.nix) killed the build identically on every
# platform, and this repo cross-builds for Windows too.
#
# It goes through flake outputs rather than `nix bundle --bundler`, because the
# bundlers read extraDirs off the derivation (`drv.extraDirs or []`) and a
# nixpkgs subject carries none -- `nix bundle --bundler . nixpkgs#hello` cannot
# express this case at all.
echo "== extraDirs contract (platform-independent) =="
SYS="$(nix eval --raw --impure --expr builtins.currentSystem)"

# Nested entries have to survive every loop that turns one into a directory.
# Phase 6's staging loop did not create the parent, so `share/assets` died on a
# bare `cp: cannot create directory ...` with no ERROR line and no phase name.
# The check also asserts the entries ARRIVED, since "builds" alone would still
# be true of a bundler that skipped them.
if nix build -L "$FLAKE#checks.$SYS.extra-dirs-nested" --no-link > nested.log 2>&1; then
  ok "nested extraDirs entries build and land at their nested paths"
else
  bad "nested extraDirs entries build and land at their nested paths" \
      "$(grep -m1 -E 'cp: cannot create directory|extraDirs contract:|error:' nested.log)"
fi

# The other way to be wrong about a nested entry: stage it nowhere, check
# nothing, exit 0. This subject hides a baked /nix/ path in a library's data
# section -- the one kind of non-portability no rewriting phase fixes -- inside
# share/probe, so the build MUST fail, and must fail by naming that file. A
# bundler that dies in the staging `cp` also "fails", which is why the message
# is what is asserted rather than the exit code.
#
# `ERROR: ` is load-bearing, not decoration. Phase 3 echoes every file it
# rewrites, share/probe/libdirty.dylib among them, so a grep for the bare path
# matches on a bundler that never staged the directory at all -- measured: it
# passed against the pre-fix bundle.sh, which had already died in Phase 6's cp.
# Only the ERROR line is Phase 6 speaking.
if nix build -L "$FLAKE#tests.$SYS.extra-dirs-dirty" --no-link > dirty.log 2>&1; then
  bad "Phase 6 looks INSIDE a nested extraDirs entry" \
      "share/probe carries a baked /nix/ path and the bundle built anyway"
elif grep -q 'ERROR: share/probe/libdirty' dirty.log; then
  ok "Phase 6 looks INSIDE a nested extraDirs entry"
else
  bad "Phase 6 looks INSIDE a nested extraDirs entry" \
      "it failed without Phase 6 naming the file: $(grep -m1 -E 'cp: cannot|error:' dirty.log)"
fi

echo

# == the Windows/PE hostLibs contract ========================================
#
# This block exists because the contract in tests/pe-hostlibs.nix was reachable
# only through `nix flake check`, and CI does not run `nix flake check` — it
# runs this file. Ten subjects that must build and eleven that must be refused
# were therefore built by nobody, which is the same as not having them.
#
# x86_64-linux only, and by SYSTEM rather than by `uname`: every subject is a
# pkgsCross.mingwW64 build, substitutable there and an hours-long GCC bootstrap
# on aarch64. Skipping is announced, so a green run on the arm runner cannot be
# read as "the PE contract passed".
if [ "$SYS" = "x86_64-linux" ]; then
  echo "== Windows/PE hostLibs contract =="

  # Must BUILD. Each asserts the resulting PE SET, not a count: the defect
  # class here is a bundle that is missing a file and exits 0.
  for c in pe-hostlibs-module pe-hostlibs-module-verified pe-hostlibs-claimed-only \
           pe-hostlibs-mixed-case pe-hostlibs-copies pe-hostlibs-bin-stripped \
           pe-hostlibs-extradirs pe-hostlibs-qtplugin-inject \
           pe-hostlibs-caller-qt pe-hostlibs-qt-dir; do
    if nix build -L "$FLAKE#checks.$SYS.$c" --no-link > "pe-$c.log" 2>&1; then
      ok "$c"
    else
      bad "$c" "$(grep -m1 -E 'ERROR:|FAIL |error:' "pe-$c.log")"
    fi
  done

  # Must FAIL, and each on a DIFFERENT arm, so the message is the assertion.
  # A subject that fails for the wrong reason is the failure this whole file is
  # written against, and exit status alone cannot tell the two apart.
  #
  # Pairs of "attribute|expected fragment", split on the `|` this loop's IFS
  # actually sets. (It said TAB, over a reader that has never been able to see
  # one — the fifth comment on this branch found describing something that is
  # not there.)
  while IFS='|' read -r c want; do
    [ -n "$c" ] || continue
    if nix build -L "$FLAKE#tests.$SYS.$c" --no-link > "pe-$c.log" 2>&1; then
      bad "$c is refused" "it built"
    elif grep -qF "$want" "pe-$c.log"; then
      ok "$c is refused, by the right arm"
    else
      bad "$c is refused, by the right arm" \
          "expected '$want'; got: $(grep -m1 -E 'ERROR:|error:' "pe-$c.log")"
    fi
  done <<'PE_FAILS'
pe-hostlibs-claim-broken|ERROR: hostLibs claims the host provides libgcc_s_seh-1.dll
pe-hostlibs-host-vacuous|has no PE file in its
pe-hostlibs-host-no-libs|ERROR: hostBundle was given but hostLibs is empty
pe-hostlibs-host-no-libs-garbage|has no PE file in its
pe-hostlibs-host-on-unix|whose target Nix reports as
pe-hostlibs-host-unknown|ERROR: hostBundle was given, but this bundle's target is not Windows
pe-hostlibs-host-not-dir|which is not a directory
pe-hostlibs-strip-everything|ERROR: the hostLibs strip removed every PE in this bundle
pe-hostlibs-qt-dir-not-host|no Qt plugin directory for this
pe-hostlibs-app-refused|but this bundle contains an executable of its own
pe-hostlibs-unclaimed|DLL import(s) could not be resolved
PE_FAILS
else
  echo "== Windows/PE hostLibs contract: SKIPPED on $SYS =="
  echo "   (every subject is a pkgsCross.mingwW64 build; only x86_64-linux runs them)"
fi

echo

# The loader path this architecture's psABI mandates. Deliberately not a single
# prefix: /lib64/ld-linux-aarch64.so.1 does not exist on current Fedora or
# openSUSE, so "just use /lib64" breaks arm64.
#
# Anything below this point is ELF-specific. Bailing out here has to report the
# tally and carry the exit status, or the assertions above would run on macOS
# and then be thrown away by an unconditional `exit 0`.
case "$(uname -m)" in
  x86_64)  PSABI=/lib64/ld-linux-x86-64.so.2 ;;
  aarch64) PSABI=/lib/ld-linux-aarch64.so.1  ;;
  *) echo "smoke: $(uname -m) is not a Linux target arch; skipping the ELF assertions"
     echo "== $pass passed, $fail failed =="
     [ "$fail" -eq 0 ]; exit ;;
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
