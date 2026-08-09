#!/bin/bash
set -euo pipefail

mkdir -p "$out"

# Build system library patterns array
system_patterns=()
if [ -n "${SYSTEM_LIBS:-}" ]; then
  while IFS= read -r pat; do
    [ -n "$pat" ] && system_patterns+=("$pat")
  done <<< "$SYSTEM_LIBS"
fi

is_system_lib() {
  local lib_name="$1"
  for pat in "${system_patterns[@]+"${system_patterns[@]}"}"; do
    # Use bash glob matching
    # shellcheck disable=SC2254
    case "$lib_name" in
      $pat) return 0 ;;
    esac
  done
  return 1
}

# Build host-provided library patterns array
host_patterns=()
if [ -n "${HOST_LIBS:-}" ]; then
  while IFS= read -r pat; do
    [ -n "$pat" ] && host_patterns+=("$pat")
  done <<< "$HOST_LIBS"
fi

is_host_lib() {
  local lib_name="$1"
  for pat in "${host_patterns[@]+"${host_patterns[@]}"}"; do
    # shellcheck disable=SC2254
    case "$lib_name" in
      $pat) return 0 ;;
    esac
  done
  return 1
}

is_portable_ref() {
  local ref="$1"
  case "$ref" in
    @executable_path/*|@loader_path/*|@rpath/*) return 0 ;;
    /System/Library/*|/usr/lib/*) return 0 ;;
    /lib/*|/lib64/*|/usr/lib64/*) return 0 ;;
    '') return 0 ;;
  esac
  # Bare library names (no path separator) are portable
  case "$ref" in
    */*) ;;
    *) return 0 ;;
  esac
  return 1
}

# ===========================================================================
# Phase 1 — Copy executables and libraries from the main derivation
# ===========================================================================
echo "Phase 1: Copying executables and libraries..."
if [ -d "$DRV_PATH/bin" ]; then
  mkdir -p "$out/bin"
  # `*` does not match dotfiles, and a bundle that already went through
  # Phase 5b has its real ELFs hidden as `.<name>.elf` beside each launcher.
  # Without the second glob, re-bundling an already-bundled tree copies the
  # launchers and silently drops the binaries they exec — leaving a bin/ whose
  # entries fail with a bare ENOENT.
  #
  # Match ONLY our own companion convention, not every dotfile: nixpkgs' Qt
  # hooks leave their own `.<name>-wrapped` C wrappers next to the binaries,
  # and those are exactly what Phase 1b below exists to strip out. Sweeping
  # them in here would ship a wrapper full of /nix/store paths.
  for f in "$DRV_PATH"/bin/* "$DRV_PATH"/bin/.*.elf; do
    [ -e "$f" ] || continue
    cp -aL "$f" "$out/bin/"
  done
  chmod -R u+w "$out/bin" 2>/dev/null || true
fi

if [ -d "$DRV_PATH/lib" ]; then
  mkdir -p "$out/lib"
  for f in "$DRV_PATH"/lib/*; do
    [ -e "$f" ] || continue
    cp -aL "$f" "$out/lib/"
  done
  chmod -R u+w "$out/lib" 2>/dev/null || true
fi

# Replace Nix Qt wrappers with their unwrapped binaries.
# wrapQtApps / makeBinaryWrapper generate compiled C wrappers that set
# QT_PLUGIN_PATH etc. to /nix/store paths and then exec a wrapped binary.
# Derivations may be double- (or multi-) wrapped, so we follow the chain by
# extracting the exec target from the wrapper's embedded strings until we
# reach a binary that is not itself a wrapper.
# The bundle uses qt.conf for plugin discovery, making the wrappers unnecessary.
if [ -d "$out/bin" ]; then
  for f in "$out"/bin/*; do
    [ -f "$f" ] || continue
    strings "$f" 2>/dev/null | grep -q 'makeCWrapper' || continue

    name="$(basename "$f")"
    # Follow the wrapper chain: extract the exec target path from the wrapper
    candidate="$f"
    while strings "$candidate" 2>/dev/null | grep -q 'makeCWrapper'; do
      # The wrapper embeds: makeCWrapper '/nix/store/.../bin/.name-wrapped' \
      target="$(strings "$candidate" 2>/dev/null | sed -n "s/^makeCWrapper '\(.*\)' .*/\1/p" | head -1)"
      if [ -z "$target" ] || [ ! -f "$target" ]; then
        echo "  Warning: cannot follow wrapper chain for $name"
        break
      fi
      candidate="$target"
    done

    if [ "$candidate" != "$f" ] && ! strings "$candidate" 2>/dev/null | grep -q 'makeCWrapper'; then
      echo "  Replacing Nix wrapper with unwrapped binary: $name"
      rm "$f"
      cp -aL "$candidate" "$f"
      chmod u+w "$f" 2>/dev/null || true
    fi
  done
fi

# Build extra dirs array
extra_dirs=()
if [ -n "${EXTRA_DIRS:-}" ]; then
  while IFS= read -r dir; do
    [ -n "$dir" ] && extra_dirs+=("$dir")
  done <<< "$EXTRA_DIRS"
fi

# Copy extra directories from the derivation
for dir in "${extra_dirs[@]+"${extra_dirs[@]}"}"; do
  if [ -d "$DRV_PATH/$dir" ]; then
    echo "  Copying extra directory: $dir"
    mkdir -p "$out/$dir"
    cp -aL "$DRV_PATH/$dir/." "$out/$dir/"
    chmod -R u+w "$out/$dir" 2>/dev/null || true
  fi
done

# ===========================================================================
# Phase 1c — What TARGET is this bundle for?
# ===========================================================================
# bundle.sh does not answer this.  mkBundle.nix does, by reading it off the
# derivation being bundled — `drv.stdenv.hostPlatform.isWindows` — and passing
# it in as IS_WINDOWS.  See mkBundle.nix for why `drv.stdenv` is the right
# source and `pkgs.stdenv` (which `isDarwin` reads) is not.
#
# This used to be an artefact heuristic here, and heuristics have no floor:
# the one that lived at this spot flipped a Linux bundle to the PE path merely
# because its bin/ shipped a .exe, and — the other direction, which is worse —
# left IS_WINDOWS=0 for a Windows derivation whose bin/ held only DLLs, so the
# whole Qt staging was skipped and the build exited 0 with an empty lib/.
#
# Artefacts are still measured below, but only to CONTRADICT Nix, never to
# decide.  The one exception is IS_WINDOWS=unknown, which means the caller
# passed a `drv` that is not an mkDerivation at all (a bare `builtins.storePath`
# or a hand-rolled `derivation`) and there is nothing authoritative to read.
#
# `file -bL`, not `file -b`: on an unresolved symlink `file -b` answers
# "symbolic link to ..." and never "PE32+", which reads as a confident zero.
IS_WINDOWS="${IS_WINDOWS:-unknown}"

# (The per-entry `file -bL` scan of bin/ that used to sit here is gone with its
# two consumers — the unknown-target fallback and the Unix-arm contradiction
# check. Both were removed above, and its three counters were then assigned and
# never read, so every non-Windows build was paying for a census nothing
# consulted.)

# Whole-tree format census.  Only ever called on a path where the answer
# changes what happens, because it is O(files) and the Unix path must not pay
# for it: see the two call sites below.
tree_pe_count=0
tree_unix_count=0
tree_census() {
  tree_pe_count=0
  tree_unix_count=0
  local f ft
  while IFS= read -r f; do
    ft="$(file -bL "$f" 2>/dev/null)" || continue
    case "$ft" in
      *PE32*)         tree_pe_count=$((tree_pe_count + 1)) ;;
      *Mach-O*|*ELF*) tree_unix_count=$((tree_unix_count + 1)) ;;
    esac
  done < <(find "$out" -type f 2>/dev/null)
  return 0
}

if [ "$IS_WINDOWS" = "unknown" ]; then
  # No `stdenv` on the drv (a bare `builtins.storePath`, a hand-rolled
  # `derivation`) — mkBundle.nix documents both as supported shapes.
  #
  # DO NOT GUESS FROM THE ARTEFACTS. An earlier revision ran a format census
  # here and inferred the target from it, which broke non-Windows builds three
  # ways on inputs the base handled fine: a storePath tree holding both a PE
  # and an ELF hard-errored where the base exited 0; a PE-only tree (the
  # ordinary wine-wrapper shape) flipped a Linux build onto the PE path
  # wholesale; and every stdenv-less build paid an O(files) `file -bL` walk it
  # never used to.
  #
  # Unix is the correct default because it is what the base always did with
  # these — a storePath bundle has never taken the PE path — so defaulting
  # costs nothing and changes nothing. `windowsTarget` already exists for the
  # caller who genuinely bundles a stdenv-less Windows tree, and an explicit
  # answer beats a census that cannot distinguish "targets Windows" from
  # "ships a .exe as data" anyway.
  IS_WINDOWS=0
elif [ "$IS_WINDOWS" = "1" ]; then
  echo "Phase 1c: target is Windows/PE (from the bundled derivation's stdenv)"
  # Nix says Windows and the output has no PE anywhere.  Do not proceed: every
  # later "0 unresolved imports" would be a measurement of nothing.
  tree_census
  if [ "$tree_pe_count" -eq 0 ]; then
    echo "  ERROR: Nix says this derivation targets Windows, but its output" >&2
    echo "  contains no PE file at all ($tree_unix_count ELF/Mach-O file(s) found)." >&2
    echo "  Something upstream produced host binaries for a cross target; a" >&2
    echo "  bundle built from this would be checked against nothing." >&2
    exit 1
  fi
  echo "  Output census: $tree_pe_count PE file(s), $tree_unix_count ELF/Mach-O file(s)"
fi
# NOTE there is deliberately no `else` arm for the Unix target.
#
# An earlier revision warned when a non-Windows output contained PEs and no
# native binary, on the theory that this is what a mis-wired cross build looks
# like. It is also exactly what a wine wrapper looks like, which is a perfectly
# ordinary package — so the warning fired on valid input, and it cost TWO
# whole-tree `file -bL` walks to produce. Nix is authoritative about the target;
# once it has answered, the artefacts have no further say and there is nothing
# to check. Staying silent here is what keeps every non-Windows bundle
# byte-identical to the base, output and logs included.

# Where the Qt plugin and QML trees get staged inside the bundle.  "qt"
# everywhere the bundler already worked; "qt-6" on Windows, which is the layout
# proven on real Windows hardware.  Either is self-consistent because qt.conf
# names whichever one was used — but they are not interchangeable, so the
# choice is made once, here, and never spelled out again.
qt_stage="qt"
if [ "$IS_WINDOWS" = "1" ]; then qt_stage="qt-6"; fi
qt_plugins_dir="$out/lib/$qt_stage/plugins"
qt_qml_dir="$out/lib/$qt_stage/qml"

if [ "$IS_WINDOWS" = "1" ]; then
  # Phase 1 copied with `cp -aL`, so every win-dll-link symlink should have
  # landed as a real file.  Assert it rather than assume it: a symlink that
  # survives into the bundle points at a relative path outside it, dangles the
  # moment the tree leaves /nix/store, and is then invisible to every
  # `find -type f` downstream — the bundle loses the file and still exits 0.
  src_bin_entries=0
  if [ -d "$DRV_PATH/bin" ]; then
    src_bin_entries="$(find "$DRV_PATH/bin" -maxdepth 1 -mindepth 1 | wc -l)"
  fi
  # Guarded on BOTH sides. The source side above already was; this one was not,
  # and a Windows output with no bin/ at all is a shape this workspace actually
  # produces -- a Logos module is `lib/<name>_plugin.dll` and nothing else, and
  # nix-bundle-lgx feeds exactly those through here. Unguarded it printed a bare
  # `find: '.../bin': No such file or directory` and died with no ERROR line and
  # no phase name, on a branch whose stated standard is to fail loudly.
  out_bin_entries=0
  out_bin_links=0
  if [ -d "$out/bin" ]; then
    out_bin_entries="$(find "$out/bin" -maxdepth 1 -mindepth 1 | wc -l)"
    out_bin_links="$(find "$out/bin" -maxdepth 1 -mindepth 1 -type l | wc -l)"
  fi
  echo "  bin/ entry count: source $src_bin_entries -> bundle $out_bin_entries" \
       "($out_bin_links symlink(s) remaining)"
  if [ "$out_bin_entries" -lt "$src_bin_entries" ]; then
    echo "  ERROR: bin/ lost entries in Phase 1 ($src_bin_entries -> $out_bin_entries)" >&2
    exit 1
  fi
  if [ "$out_bin_links" -gt 0 ]; then
    echo "  ERROR: bin/ still contains $out_bin_links symlink(s); they will dangle" >&2
    find "$out/bin" -maxdepth 1 -mindepth 1 -type l -printf '    %f -> %l\n' >&2
    exit 1
  fi
fi

# ---------------------------------------------------------------------------
# PE (Windows) helpers
# ---------------------------------------------------------------------------
# Every function below is only ever *called* under `[ "$IS_WINDOWS" = "1" ]`;
# defining them unconditionally costs nothing and keeps the platform branching
# in one place further down.

# DLLs that Windows itself provides.  Resolving these out of the Nix closure is
# both impossible and wrong — they must come from the host — so they are the
# one thing the fixpoint sweep is allowed to skip.
#
# Matched case-INsensitively: an import table spells the same library
# "KERNEL32.dll" in one binary and "kernel32.dll" in the next, and a
# case-sensitive miss surfaces only as a build failure for a DLL that never
# needed resolving in the first place.
#
# Deliberately NOT routed through SYSTEM_LIBS / useDefaultSystemLibs: a caller
# passing `useDefaultSystemLibs = false` is talking about glibc and Mesa, and
# must not thereby be asking the bundler to vendor kernel32.dll.
is_windows_system_dll() {
  local n="${1,,}"
  case "$n" in
    api-ms-win-*|ext-ms-*)                                    return 0 ;;
    ntdll.dll|kernel32.dll|kernelbase.dll|user32.dll)         return 0 ;;
    gdi32.dll|gdi32full.dll|gdiplus.dll|comdlg32.dll)         return 0 ;;
    advapi32.dll|sechost.dll|rpcrt4.dll|combase.dll)          return 0 ;;
    ole32.dll|oleaut32.dll|oleacc.dll|olepro32.dll)           return 0 ;;
    shell32.dll|shlwapi.dll|shcore.dll|comctl32.dll)          return 0 ;;
    msvcrt.dll|ucrtbase.dll|msvcp_win.dll)                    return 0 ;;
    vcruntime140.dll|vcruntime140_1.dll|msvcp140.dll)         return 0 ;;
    ws2_32.dll|wsock32.dll|mswsock.dll|winhttp.dll)           return 0 ;;
    wininet.dll|iphlpapi.dll|dnsapi.dll|netapi32.dll)         return 0 ;;
    crypt32.dll|bcrypt.dll|bcryptprimitives.dll)              return 0 ;;
    ncrypt.dll|secur32.dll|wintrust.dll|cryptbase.dll)        return 0 ;;
    dbghelp.dll|dbgcore.dll|version.dll|psapi.dll)            return 0 ;;
    winmm.dll|avicap32.dll|msimg32.dll|imm32.dll)             return 0 ;;
    userenv.dll|profapi.dll|dwmapi.dll|uxtheme.dll)           return 0 ;;
    setupapi.dll|cfgmgr32.dll|hid.dll|wtsapi32.dll)           return 0 ;;
    mpr.dll|powrprof.dll|propsys.dll|authz.dll)               return 0 ;;
    winspool.drv|mf.dll|mfplat.dll|mfreadwrite.dll|evr.dll)   return 0 ;;
    opengl32.dll|glu32.dll|d3d9.dll|d3d11.dll|d3d12.dll)      return 0 ;;
    d2d1.dll|d3d10*.dll|dxva2.dll|dxgi.dll|dcomp.dll)         return 0 ;;
    dwrite.dll|windowscodecs.dll|directxmath.dll)             return 0 ;;
    odbc32.dll|odbccp32.dll|oledlg.dll|msdasql.dll)           return 0 ;;
    normaliz.dll|pdh.dll|winscard.dll|usp10.dll)              return 0 ;;
    msvfw32.dll|winusb.dll|cabinet.dll|urlmon.dll|t2embed.dll) return 0 ;;
  esac
  return 1
}

# --- is this file a PE? -----------------------------------------------------
# Memoised, because the fixpoint sweep re-walks the whole output once per round
# and a Basecamp bundle is ~2 GB.  A file's contents never change once staged,
# so one answer per path is enough for the entire build.
#
# The "MZ" prefilter is not micro-optimisation: without it this is one `file`
# process per file per round, which on an 8-round sweep over ~20k files is
# ~160k process spawns.  `read -N 2` is a bash builtin and spawns nothing.
# Every PE begins with "MZ" (IMAGE_DOS_HEADER.e_magic), so a non-MZ file cannot
# be a PE and the prefilter cannot produce a false negative.
declare -A pe_filetype_cache
pe_is_pe() {
  local f="$1" ft magic
  # `-f` first, and it is not redundant with the read below.  Two shapes reach
  # this function that are not regular files: a DIRECTORY whose name matches an
  # import (see pe_dir_index), and a DANGLING symlink.  `read < "$dir"` fails
  # with "Is a directory", and because the shell performs `< "$f"` BEFORE the
  # `2>/dev/null` on the same command, that message lands on the build log with
  # no phase and no explanation.  `-f` follows symlinks, so a symlink to a real
  # file still gets classified.
  [ -f "$f" ] || return 1
  ft="${pe_filetype_cache["$f"]:-}"
  if [ -z "$ft" ]; then
    magic=""
    IFS= read -r -N 2 magic < "$f" 2>/dev/null || true
    if [ "$magic" = "MZ" ]; then
      # `file -bL`, not `file -b`: on a symlink `file -b` answers "symbolic
      # link to ..." and never "PE32+", which reads as a confident "not a PE".
      ft="$(file -bL "$f" 2>/dev/null)" || ft="?"
      [ -n "$ft" ] || ft="?"
    else
      ft="not-MZ"
    fi
    pe_filetype_cache["$f"]="$ft"
  fi
  [[ "$ft" == *PE32* ]]
}

# --- what MACHINE is this PE for? -------------------------------------------
# `*PE32*` — the test pe_is_pe applies — accepts 32-bit PE32, 64-bit PE32+ and
# ARM64 alike, and nothing else on the PE path ever looked at the machine field:
# an import was resolved by NAME, so a closure carrying both an i686 and an
# x86-64 copy of a name resolved by priority then store-hash order and the
# loser's architecture was never mentioned.  On Windows a wrong-machine DLL is
# ERROR_BAD_EXE_FORMAT at load time, i.e. the same silent pre-main() death this
# branch exists to convert into a build error.
#
# Read from the FILE FORMAT, not from `file`'s prose.  An earlier version of
# this function pattern-matched the `file -bL` string pe_is_pe already caches,
# which cost no extra read and looked free.  It is not free: `file` describes an
# i686 PE as "Intel 80386" up to 5.45 and "Intel i386" from 5.46, so the x86 arm
# stopped matching on a `file` bump, fell through to `unknown`, and BOTH call
# sites treated unknown as "carry on".  Measured: with nixpkgs' own file-5.48 in
# place of the pinned 5.45, and nothing else changed, a bundle shipping an i686
# DLL beside an x86-64 exe built green.  A machine check whose correctness
# depends on an unpinned tool's wording is not a machine check.
#
# IMAGE_DOS_HEADER.e_lfanew (4 bytes LE at 0x3C) points at the PE signature;
# IMAGE_FILE_HEADER.Machine is the 2 LE bytes just past it.  Composed from
# single bytes on purpose — `od -tu4`/`-tx2` decode in the BUILD HOST's byte
# order, which is only accidentally right on the hosts we happen to use.
#
# Unrecognised is FATAL at both call sites, not a note: every PE has a Machine
# field, so "I could not tell" means the reader or the file is wrong, and the
# failure this check exists to catch (ERROR_BAD_EXE_FORMAT before main(), no
# output) is exactly the one a soft fallback lets through.
declare -A pe_arch_cache
pe_arch() {
  local f="$1" bytes lfanew mach
  if ! pe_is_pe "$f"; then printf 'not-pe\n'; return 0; fi
  # Memoised for the same reason pe_is_pe is: Phase 6 asks for the architecture
  # of an importer and of a provider once per import name, ~2300 times on a
  # Basecamp bundle, and each answer is two `od` spawns.
  if [ -n "${pe_arch_cache["$f"]:-}" ]; then
    printf '%s\n' "${pe_arch_cache["$f"]}"
    return 0
  fi
  mach=""
  # shellcheck disable=SC2207
  bytes=($(od -An -tu1 -j60 -N4 -- "$f" 2>/dev/null)) || bytes=()
  if [ "${#bytes[@]}" -eq 4 ]; then
    lfanew=$(( bytes[0] + (bytes[1] << 8) + (bytes[2] << 16) + (bytes[3] << 24) ))
    if [ "$lfanew" -gt 0 ]; then
      # shellcheck disable=SC2207
      bytes=($(od -An -tu1 -j"$lfanew" -N6 -- "$f" 2>/dev/null)) || bytes=()
      # "PE\0\0" — refuse to read a Machine field out of a header that is not
      # there rather than reporting whatever those two bytes happen to be.
      if [ "${#bytes[@]}" -eq 6 ] && [ "${bytes[0]}" -eq 80 ] && [ "${bytes[1]}" -eq 69 ] \
         && [ "${bytes[2]}" -eq 0 ] && [ "${bytes[3]}" -eq 0 ]; then
        mach="$(printf '%04x' $(( bytes[4] + (bytes[5] << 8) )))"
      fi
    fi
  fi
  case "$mach" in
    8664) mach=x86-64 ;;
    014c) mach=x86 ;;
    aa64) mach=arm64 ;;
    01c0|01c4) mach=arm ;;
    "")   mach=unknown ;;
    *)    mach="machine-0x$mach" ;;
  esac
  pe_arch_cache["$f"]="$mach"
  printf '%s\n' "$mach"
}

# One place decides what an unusable architecture answer means, so the sweep and
# Phase 6 cannot drift apart on it again.  `not-pe` is included: both callers
# have already established their argument is a PE, so it can only mean the file
# changed underneath us.
pe_arch_or_die() {
  local f="$1" what="$2" a
  a="$(pe_arch "$f")"
  case "$a" in
    x86-64|x86|arm64|arm) printf '%s\n' "$a"; return 0 ;;
  esac
  echo "  ERROR: cannot determine the machine of $what:" >&2
  echo "      $f" >&2
  echo "  read it as '$a'.  Every PE carries IMAGE_FILE_HEADER.Machine, so this" >&2
  echo "  is a truncated or non-PE file, or an architecture this bundler has" >&2
  echo "  never been taught.  Windows answers a wrong-machine DLL with" >&2
  echo "  ERROR_BAD_EXE_FORMAT before main() runs and prints nothing, so this" >&2
  echo "  is not something to carry on past." >&2
  exit 1
}

# --- does this bundle render QML? -------------------------------------------
# Defined HERE, with the other PE helpers, rather than inside Phase 2b's
# `qt_detected` branch where it used to live: Phase 6 needs the same predicate,
# and a function defined inside an `if` that did not run does not exist.  The
# consequence was worse than a missing function — Phase 6 could not ask the
# gate, so it asserted `qt_qml_found=1 => bin/Qt6Quick.dll` while the gate fires
# on Qt6Qml*.dll too.  A QtQml-without-QtQuick bundle that legitimately stages
# QML modules was therefore a hard build failure.
#
# These DLLs are in bin/ only because the DLL closure sweep put them there: the
# .exe imports neither Qt6Qml nor Qt6Quick, the UI plugin does.  That is why
# this is a FUNCTION and not a one-shot test — see Phase 2e, which re-asks.
win_qml_gate() {
  local f
  for f in "$out"/bin/Qt6Qml*.dll "$out"/bin/Qt6Quick*.dll \
           "$out"/bin/Qt5Qml*.dll "$out"/bin/Qt5Quick*.dll; do
    [ -e "$f" ] && return 0
  done
  return 1
}

# --- every PE in the bundle -------------------------------------------------
# ONE enumeration, used by BOTH the fixpoint sweep and Phase 6's validator.
#
# v1 had two independent ones and they drifted, which is a build failure on
# valid input rather than a style complaint: the sweep walked bin/ at maxdepth
# 1, *.dll under the staged Qt tree, and *.dll/*.exe under declared extraDirs,
# while the verifier walked `find "$out" -type f`.  A PE anywhere else — under
# $out/lib outside the Qt stage (which Phase 1 populates and the app-QML
# symlink pass at the end of Phase 2b explicitly expects), under a bin/
# subdirectory, under libexec/ or share/, or with a non-.dll extension such as
# .pyd/.ocx/.drv/.cpl — was never swept but always checked, so the build died
# on a dependency that was in the closure all along and blamed the closure for
# it.  Demonstrated twice, independently, on two different relocations.
#
# Selection is by CONTENT, not by suffix, for the same reason.
#
# `find -type f` does not descend directory symlinks, and the app-QML pass
# creates exactly those under the staged QML tree — but their targets are real
# files under $out/lib, which this walk reaches by their real path, so nothing
# is lost.  Sorted so the walk order is deterministic.
#
# `-type f` also means a PE that IS a symlink is invisible here.  Left that way
# deliberately, and stated so the next reader does not re-derive it: the
# blindness is SYMMETRIC (the sweep and the verifier share this enumeration, so
# it can only under-check, never fail spuriously), it is unreachable on this
# path (Phase 1 copies with `cp -aL`, Phase 1c rejects any symlink surviving in
# bin/, Phase 6 rejects any dangling link anywhere, and the real bundle has
# zero symlinks), and Phase 1c's census — which decides whether a Windows build
# may proceed at all — uses the same `-type f`, so widening only this one would
# not make a symlink-only tree reachable.  Widening it WOULD walk the same PE
# twice whenever a link and its target are both inside the bundle.
pe_files() {
  local f
  while IFS= read -r f; do
    pe_is_pe "$f" && printf '%s\n' "$f"
  done < <(find "$out" -type f 2>/dev/null | sort)
  # Explicit, and not cosmetic: without it the function's status is that of the
  # last `pe_is_pe`, so a tree whose last file is not a PE returns 1 — and under
  # `set -e` a caller that redirects (`pe_files > "$list"`) then dies with no
  # message at all.  That is a silent exit 1 in the middle of the success path.
  return 0
}

# --- the PE import-table reader ---------------------------------------------
# PE_OBJDUMP comes from the TARGET's own bintools (see mkBundle.nix).  The
# fallback to bare `objdump` exists for `windowsTarget = true` on a derivation
# with no cross toolchain to borrow from; it is NOT a preference.  Either way
# pe_reader_control below proves the chosen reader actually reads PEs before
# any zero it returns is believed.
pe_objdump=""
# Where pe_imports records what the reader said about ITSELF.
#
# Files, not shell variables, and that is the whole point.  Every call site
# reads pe_imports through a process substitution or a pipeline
# (`done < <(pe_imports "$f")`, `pe_imports "$f" | grep -c .`), so the function
# body runs in a SUBSHELL and every variable it sets is discarded when it
# returns.  That is also why the associative-array memo this function used to
# keep never once hit: it was written in a subshell and read in the parent.  A
# cache that cannot hit is only a lie about cost; an error channel that cannot
# survive is a defect, because it makes a failed read look like a clean one.
# Appending to a file is the single thing a subshell can do that the parent sees.
pe_reader_errlog=""
pe_reader_zerolog=""
pe_resolve_objdump() {
  local c
  for c in "${PE_OBJDUMP:-}" objdump; do
    [ -n "$c" ] || continue
    if command -v "$c" >/dev/null 2>&1; then
      pe_objdump="$c"
      pe_reader_errlog="$(mktemp)"
      pe_reader_zerolog="$(mktemp)"
      return 0
    fi
  done
  echo "  ERROR: no PE import-table reader is available.  PE_OBJDUMP was" >&2
  echo "  '${PE_OBJDUMP:-}' and no 'objdump' is on PATH; a Windows bundle" >&2
  echo "  cannot be verified without one." >&2
  exit 1
}

# The reader's stderr is CAPTURED, not discarded, and that is the whole of the
# fix here.
#
# `2>/dev/null` threw away the only channel this reader has for saying it
# failed, and the exit status says nothing either: objdump exits 0 when it
# cannot parse the file it was handed (measured: it prints
# "(.idata) is too large" on a truncated PE and returns 0).  So
# "this PE's import table could not be read" and "this PE imports nothing"
# produced the IDENTICAL observation — an empty list — and both the sweep and
# Phase 6 took the second reading.  Neither has a per-file zero check;
# pe_reader_control below returns as soon as ONE file yields imports, so it
# proves nothing about the rest, and Phase 6 only rejects a GLOBAL zero.
# Demonstrated: a bundle holding a truncated Qt6Core.dll built clean and
# announced that "every import name resolves", having never read that file's
# table at all.
#
# Nothing is decided here — a subshell cannot fail the build — so the two
# findings are appended to files and adjudicated by the two functions below,
# in the parent, at points where exiting works.
pe_imports() {
  local f="$1" errf out
  errf="$(mktemp)"
  out="$("$pe_objdump" -p "$f" 2>"$errf" \
    | sed -n 's/^[[:space:]]*DLL Name:[[:space:]]*//p')" || true
  if [ -s "$errf" ]; then
    { printf 'FILE %s\n' "$f"; sed 's/^/      /' "$errf"; } >> "$pe_reader_errlog"
  fi
  rm -f "$errf"
  [ -n "$out" ] || printf '%s\n' "$f" >> "$pe_reader_zerolog"
  printf '%s\n' "$out"
}

# A read that FAILED is fatal.  Called after every sweep, so the build dies at
# the first phase whose decisions were made on unreadable data rather than at
# the end, and again in Phase 6.  Silent when there is nothing to say: this runs
# on the success path of every Windows build.
pe_assert_reader_read_everything() {
  local where="$1" nerr
  [ -n "$pe_reader_errlog" ] && [ -s "$pe_reader_errlog" ] || return 0
  nerr="$(grep -c '^FILE ' "$pe_reader_errlog" || true)"
  echo "  ERROR ($where): the PE import reader wrote to stderr for $nerr file(s)." >&2
  echo "  objdump exits 0 when it cannot parse a PE, so an unreadable import" >&2
  echo "  table is indistinguishable from an empty one — and an empty one is" >&2
  echo "  read as 'every import already satisfied'.  Nothing this build says" >&2
  echo "  about those files' dependencies is a measurement." >&2
  sed 's/^/    /' "$pe_reader_errlog" >&2
  exit 1
}

# Zero imports is NOT fatal and must not be: a resource-only DLL — an ICU data
# blob, a Qt translations catalogue — genuinely imports nothing and is a
# perfectly ordinary member of a bundle.  What was missing is that nobody ever
# said how many there were, so the one shape that matters (a file whose table
# was never read) was invisible inside a number nobody printed.
pe_report_zero_import_files() {
  local nzero=0
  if [ -n "$pe_reader_zerolog" ] && [ -s "$pe_reader_zerolog" ]; then
    nzero="$(sort -u "$pe_reader_zerolog" | wc -l)"
  fi
  echo "  PE files declaring no imports at all: $nzero"
  [ "$nzero" -gt 0 ] || return 0
  sort -u "$pe_reader_zerolog" | sed "s#^$out/#      #"
  echo "      (legitimate for a resource-only DLL; listed because an unreadable"
  echo "      import table looks exactly like an empty one)"
}

# --- known-positive control for the reader ----------------------------------
# Run BEFORE the first sweep, not in Phase 6, because every sweep decision
# downstream depends on it.  A broken reader and a complete bundle are the same
# observation — an empty import list — and the only thing that separates them is
# whether SOME PE in the bundle yields imports, since a PE that imports nothing
# at all cannot even call the C runtime.
#
# Any PE will do, including a DLL.  v1 required a PE *executable* and therefore
# exited 1 on a Windows output whose bin/ holds only DLLs.
#
# The failure this guards against is not hypothetical in the general case:
# x86_64-linux binutils happens to support pei-x86-64, but an objdump built for
# a builder without a PE target reports zero imports for every file and exits 0.
pe_reader_control() {
  local f n probed=0 list
  # Via a temp file rather than a process substitution: this loop returns as
  # soon as it finds a positive, which would leave pe_files writing into a
  # closed pipe and print a spurious "printf: write error: Broken pipe" from
  # inside the success path.
  list="$(mktemp)"
  pe_files > "$list"
  while IFS= read -r f; do
    probed=$((probed + 1))
    n="$(pe_imports "$f" | grep -c . || true)"
    if [ "$n" -gt 0 ]; then
      echo "  Import-reader control ($pe_objdump): ${f#"$out"/} declares" \
           "$n import(s) — the reader works"
      rm -f "$list"
      return 0
    fi
  done < "$list"
  rm -f "$list"
  echo "  ERROR: the import reader ($pe_objdump) returned ZERO imports for all" >&2
  echo "  $probed PE file(s) in this bundle.  A PE that imports nothing cannot" >&2
  echo "  call the C runtime, so this is a broken reader, not a clean bundle —" >&2
  echo "  and every later 'all imports resolve' would be a measurement of" >&2
  echo "  nothing.  Check that PE_OBJDUMP targets pei-x86-64." >&2
  exit 1
}

# name (lowercased) -> providing file, for every loadable PE module in the
# closure.
declare -A pe_dll_index
declare -A pe_dll_prio
declare -A pe_dll_alts

pe_build_dll_index() {
  local list sp p parent key prio total nonpe=0
  list="$(mktemp)"
  # No -maxdepth.  v1 capped it at 6, which on the real closure hid 29 of 402
  # DLLs (all QML style plugins nested 7-8 deep); nothing imported them by name,
  # so it was harmless there and would have been silent anywhere else — a
  # runtime library installed deeper than 6 levels would have come back
  # "not in the closure".
  #
  # -iname, not -name: import names are lowercased at lookup, so a provider
  # spelled LIBSPDLOG.DLL never entered the index and the claimed
  # case-insensitivity was one-sided.  Demonstrated: renaming the provider
  # turned a staged DLL into a build failure.
  #
  # The suffix list decides what is a CANDIDATE, not what is a provider: an
  # import name is a filename, so the search has to start from names, but the
  # `pe_is_pe` test below is what decides whether a candidate can satisfy
  # anything.  The extension list is the set of PE module extensions Windows
  # loads by name.
  #
  # `find -L`, not `find`: a closure entry whose subdirectory is a SYMLINK to a
  # directory is not descended otherwise, and 59 provider files in the real
  # Basecamp closure sit behind exactly that.  It was harmless there only
  # because the same files were reachable through another closure root; a
  # package that ships its DLLs solely under a symlinked directory would have
  # come back "not in the closure", which is a build failure blaming the input.
  # With -L a symlink to a file is already `-type f`, so `-type l` now matches
  # only DANGLING links — which pe_is_pe rejects, as it should.
  while IFS= read -r sp; do
    [ -d "$sp" ] || continue
    find -L "$sp" \( -type f -o -type l \) \
      \( -iname '*.dll' -o -iname '*.drv' -o -iname '*.ocx' \
         -o -iname '*.cpl' -o -iname '*.pyd' \) 2>/dev/null || true
  done < "$CLOSURE_PATHS" | sort -u > "$list"
  while IFS= read -r p; do
    # Being NAMED like a module is not being one.  The D7/D11 fix made the ROOT
    # side select by content and left this side selecting by suffix, so the two
    # halves of the same question disagreed: a 68-byte text file called
    # evil.dll entered the index, "satisfied" a real import table entry, was
    # copied into bin/, and the build declared the closure complete.
    # Demonstrated with a matched control (no provider at all -> correct exit 1).
    # On Windows that bundle is 0xC0000135 before main() — the exact failure
    # this branch exists to turn into a build error.
    if ! pe_is_pe "$p"; then
      nonpe=$((nonpe + 1))
      continue
    fi
    parent="$(basename "$(dirname "$p")")"
    # Prefer the canonical install locations.  MinGW puts runtime DLLs in
    # bin/, occasionally in lib/; anything found deeper (e.g. a plugin) is a
    # last resort so that a plugin copy never shadows the real library.
    prio=3
    [ "$parent" = "bin" ] && prio=1
    [ "$parent" = "lib" ] && prio=2
    key="$(basename "$p")"
    key="${key,,}"
    if [ -z "${pe_dll_prio[$key]:-}" ] || [ "$prio" -lt "${pe_dll_prio[$key]}" ]; then
      pe_dll_index[$key]="$p"
      pe_dll_prio[$key]="$prio"
      pe_dll_alts[$key]="$p"
    elif [ "$prio" -eq "${pe_dll_prio[$key]}" ]; then
      pe_dll_alts[$key]="${pe_dll_alts[$key]} $p"
    fi
  done < "$list"
  total="$(wc -l < "$list")"
  rm -f "$list"
  # `+x` form: under `set -u`, ${#arr[@]} on an assoc array that never received
  # an element is itself an error, which would pre-empt the message below.
  local indexed=0
  [ -n "${pe_dll_index[*]+x}" ] && indexed="${#pe_dll_index[@]}"
  echo "  DLL index: $indexed distinct name(s) from $((total - nonpe)) PE" \
       "file(s) across the closure (sorted; first-wins within a priority);" \
       "$nonpe of $total name-matching file(s) rejected as not-a-PE"
  # Not fatal, and deliberately so: a package may legitimately ship a *.dll that
  # is data (an ICU stub, a stray text file), and rejecting it is the correct
  # outcome, not an error.  What must never happen again is rejecting it
  # SILENTLY in one direction and accepting it silently in the other, so the
  # count is always printed — including the zero.
  # NOT fatal.  v1 exited here, one line after announcing IS_WINDOWS=1, and so
  # failed `pkgsCross.mingwW64.hello` — a self-contained executable whose only
  # imports are KERNEL32 and msvcrt legitimately has no .dll in its closure and
  # needs nothing staged.  The reader control above is what makes a later zero
  # trustworthy; this number is a fact about the input, so state it.
  if [ "$indexed" -eq 0 ]; then
    echo "  Note: the dependency closure contains no loadable PE module at all." \
         "Nothing can be staged from it; every import will have to be satisfied" \
         "by the host (a system DLL) or the build will say which one is missing."
  fi
  pe_report_ambiguous_providers
}

# Ambiguity is normal and is NOT an error: 18 identical copies of libgcc are
# what a Nix closure looks like.  What is not normal — and is the documented
# Windows duplicate-statics shape — is two providers of the same name with
# DIFFERENT content, where "first-wins" silently picks one.  Measured on the
# real closure: 24 ambiguous names, every candidate set content-identical, so
# this is silent on today's input and speaks exactly when it should.
pe_report_ambiguous_providers() {
  [ -n "${pe_dll_alts[*]+x}" ] || return 0
  local key alts n ambiguous=0 diverging=0 h hashes
  while IFS= read -r key; do
    alts="${pe_dll_alts[$key]}"
    # shellcheck disable=SC2086
    set -- $alts
    n=$#
    [ "$n" -gt 1 ] || continue
    ambiguous=$((ambiguous + 1))
    hashes="$(for h in "$@"; do sha256sum "$h" 2>/dev/null | cut -d' ' -f1; done | sort -u | wc -l)"
    if [ "$hashes" -gt 1 ]; then
      diverging=$((diverging + 1))
      echo "  WARNING: $n providers of '$key' differ in CONTENT; using" \
           "${pe_dll_index[$key]}" >&2
      for h in "$@"; do echo "      $h" >&2; done
    fi
  done < <(printf '%s\n' "${!pe_dll_alts[@]}" | sort)
  echo "  Provider ambiguity: $ambiguous name(s) have >1 provider at the same" \
       "priority; $diverging of them differ in content"
}

# Case-insensitive "does this directory contain this name", memoised.  The
# value is the entry's REAL basename, not a bare 1, because a case-insensitive
# hit still has to be copied by its actual name.
declare -A pe_dir_have
declare -A pe_dir_scanned

pe_dir_index() {
  local d="$1" e key
  [ -n "${pe_dir_scanned["$d"]:-}" ] && return 0
  pe_dir_scanned["$d"]=1
  [ -d "$d" ] || return 0
  for e in "$d"/*; do
    # `-f`, not `-e`. A DIRECTORY named like an imported DLL used to satisfy
    # both the sweep and Phase 6's re-check: with an empty `bin/libdir.dll/`
    # present the sweep reported "0 DLL(s) added", converged, staged nothing and
    # raised nothing. pe_is_pe below now rejects it on content too, but `-f`
    # rejects it before the read, which is what keeps a bare
    # "Is a directory" out of the build log (the redirection fails before the
    # command's own `2>/dev/null` is in effect).
    [ -f "$e" ] || continue
    # Index only ACTUAL PEs. This used to record every directory entry
    # regardless of content, and the index is what decides whether an import is
    # satisfied -- so a plain text file named libcurl-4.dll "satisfied" the
    # import and was even mirrored into bin/, while the sweep reported a
    # complete closure. Reproduced with a matched control: replacing one real
    # DLL with `printf 'PLACEHOLDER - not a PE'` changed nothing the script
    # said, and the loader would then fail at 0xC0000135 against a bundle this
    # very script had just called verified. Name and existence are not
    # satisfaction; being loadable is.
    pe_is_pe "$e" || continue
    key="$(basename "$e")"
    pe_dir_have["$d|${key,,}"]="$key"
  done
  return 0
}

# import name -> space-separated list of importers that wanted it
declare -A pe_unresolved
pe_staged_total=0
pe_mirrored_total=0

# WHERE staged DLLs go, resolved ONCE and readable from every phase that has to
# NAME that destination.  Phase 1 has run by the time the first sweep does, so
# bin/ either exists or never will.
#
# It is a global and not just pe_sweep's local because four later messages spell
# the destination out ("staged into bin/", "resolved from bin/", ...) and every
# one of them was unconditional: on a module-only output, which has no bin/ and
# stages beside the importer, they each pointed the reader at a directory that
# is not in the bundle.  That is the same defect as naming bin/ in the
# unresolved-import error, and one fix should cover all of them.
pe_app_dir=""
pe_app_dir_resolved=""
pe_stage_label="bin/"
pe_resolve_app_dir() {
  [ -n "$pe_app_dir_resolved" ] && return 0
  pe_app_dir_resolved=1
  if [ -d "$out/bin" ]; then
    pe_app_dir="$out/bin"
    pe_stage_label="bin/"
  else
    pe_app_dir=""
    pe_stage_label="each importer's own directory"
  fi
  return 0
}

# Walk the import tables of every root, stage what is missing into bin/, and
# REPEAT until a round adds nothing.
#
# One pass is provably not enough: you cannot read the imports of a DLL that is
# not there yet.  Measured on real Windows, Basecamp needed four rounds
# (liblogos_core -> libfmt/libspdlog/libpackage_manager_lib -> liblgx ->
# icuuc/libsodium -> icudt), and the Qt side needs a further round because
# Qt6QmlCore is reachable only through a LoadLibrary'd QML plugin.
pe_sweep() {
  local label="$1"
  local round=0 added root rootdir imp key src dest roots_seen beside_name
  local dest_name root_arch src_arch app_dir stage_dir
  echo "  DLL closure sweep ($label):"
  # WHERE a missing DLL goes.  bin/ is the application's own directory, which
  # Windows searches for every module in the process, so for an app bundle it is
  # the one destination that always works — and that is what this swept into,
  # unconditionally.
  #
  # But nothing on this path ever CREATED bin/: Phase 1 makes it only when the
  # derivation has one.  A Windows output with no bin/ at all is a shape this
  # workspace really produces — a Logos module is `lib/<name>_plugin.dll` and
  # nothing else — and for those the first `cp` into the missing directory ended
  # the build on a bare `cp: ... No such file or directory`, no ERROR line, no
  # phase name, under `set -e`, which also pre-empted the post-condition below
  # that was supposed to attribute exactly this.
  #
  # `mkdir -p "$out/bin"` would make it exit 0 and be WRONG: a module is
  # installed into someone else's tree (lgpm puts it in `modules/<name>/`), so a
  # bin/ invented here is a directory Windows never searches for that plugin,
  # and the DLLs would be shipped where they cannot be found — green build, dead
  # module, which is the whole defect class this branch exists to close.  The
  # directory that IS searched for a plugin loaded with
  # LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR (which logos-module sets) is the plugin's
  # own, so that is where they go.
  pe_resolve_app_dir
  app_dir="$pe_app_dir"
  if [ -n "$app_dir" ]; then
    pe_dir_index "$app_dir"
  else
    echo "    (no bin/ in this output: staging beside each importer, which is the" \
         "only directory Windows searches for a module loaded from it)"
  fi
  while :; do
    round=$((round + 1))
    added=0
    roots_seen=0
    while IFS= read -r root; do
      roots_seen=$((roots_seen + 1))
      rootdir="$(dirname "$root")"
      pe_dir_index "$rootdir"
      while IFS= read -r imp; do
        [ -n "$imp" ] || continue
        is_windows_system_dll "$imp" && continue
        key="${imp,,}"
        stage_dir="${app_dir:-$rootdir}"
        # bin/ first: that is the executable's own directory, which Windows
        # always searches, for every module in the process.  With no bin/ there
        # is no such directory and the importer's own is the only candidate,
        # which the beside-the-importer test below already covers.
        if [ -n "$app_dir" ]; then
          [ -n "${pe_dir_have["$app_dir|$key"]:-}" ] && continue
        fi
        # "Sits beside the importer" satisfies the CHECK, but it is not a
        # guarantee the bundler can make: the loader only searches the
        # importing MODULE's directory when that module was loaded with
        # LOAD_WITH_ALTERED_SEARCH_PATH (or AddDllDirectory), which is a
        # property of the LoadLibrary call site, not of the bundle, and is not
        # inherited by a dependency-of-a-dependency.  Measured on the real
        # bundle: 12 DLLs were satisfied ONLY by this rule.
        #
        # So mirror a copy into bin/ as well.  Strictly additive (~12 files,
        # a few MB), it never shadows anything — the bin/ test above already
        # returned — and it converts an assumption about a loader flag into a
        # file that is simply there.
        if [ -n "${pe_dir_have["$rootdir|$key"]:-}" ]; then
          # With no app dir there is nowhere to mirror TO, and nothing to gain:
          # beside-the-importer is not a weaker guarantee than bin/ here, it is
          # the only one there is.
          if [ -n "$app_dir" ] && [ "$rootdir" != "$app_dir" ]; then
            beside_name="${pe_dir_have["$rootdir|$key"]}"
            # The same explicit check the staging path makes, for the same
            # reason and with the same wording.  Without it a DIRECTORY named
            # like the import at $app_dir/<name> makes `cp -L` succeed *into*
            # it, and the failure surfaces only as the generic post-condition
            # below — which fails closed, but names the copy rather than the
            # directory that caused it.  Only the staging path had this, so the
            # two halves of the same decision reported the same situation
            # differently depending on which one hit it first.
            if [ -d "$app_dir/$beside_name" ]; then
              echo "  ERROR: cannot mirror $beside_name into ${app_dir#$out/}/: a" >&2
              echo "  DIRECTORY of that name is already there.  A directory cannot" >&2
              echo "  satisfy an import, and overwriting it is not something this" >&2
              echo "  script should guess at." >&2
              exit 1
            fi
            cp -L "$rootdir/$beside_name" "$app_dir/$beside_name" || {
              echo "  ERROR: could not mirror $beside_name from ${rootdir#$out/}" \
                   "into ${app_dir#$out/}" >&2
              exit 1
            }
            chmod u+w "$app_dir/$beside_name" 2>/dev/null || true
            unset 'pe_filetype_cache[$app_dir/$beside_name]'
            unset 'pe_arch_cache[$app_dir/$beside_name]'
            # Post-condition, as the staging path below already has. This
            # branch used to copy and record with no check at all, so a failed
            # or truncated copy still marked the import satisfied. `pe_is_pe`
            # is included for the same reason it is below: what gets RECORDED
            # as satisfying an import has to be a loadable module, not a file
            # with the right name.
            if [ -L "$app_dir/$beside_name" ] || [ ! -s "$app_dir/$beside_name" ] \
               || ! pe_is_pe "$app_dir/$beside_name"; then
              echo "  ERROR: mirroring $beside_name from ${rootdir#$out/} produced no usable file" >&2
              exit 1
            fi
            pe_dir_have["$app_dir|$key"]="$beside_name"
            pe_mirrored_total=$((pe_mirrored_total + 1))
            added=$((added + 1))
            echo "    round $round  ~ $beside_name  mirrored into bin/ from" \
                 "${rootdir#$out/} (was reachable only by the beside-the-importer rule)"
          fi
          continue
        fi
        src="${pe_dll_index[$key]:-}"
        if [ -z "$src" ]; then
          pe_unresolved["$imp"]="${pe_unresolved["$imp"]:-}${root#$out/} "
          continue
        fi
        # A provider must be for the SAME MACHINE as the module importing it.
        # Nothing on this path checked, so a closure carrying both an i686 and
        # an x86-64 copy of a name resolved by priority then store-hash order
        # and shipped whichever came first.  Windows answers a wrong-machine
        # DLL with ERROR_BAD_EXE_FORMAT at load time — again before main(),
        # again with no output.  Fatal, not a warning: there is no reading of
        # "the app is 64-bit and its dependency is 32-bit" that ships.
        root_arch="$(pe_arch_or_die "$root" "the PE importing $imp")"
        src_arch="$(pe_arch_or_die "$src" "the closure's provider of $imp")"
        if [ "$root_arch" != "$src_arch" ]; then
          echo "  ERROR: ${root#$out/} is $root_arch but the only provider of" >&2
          echo "  $imp in the closure is $src_arch:" >&2
          echo "      $src" >&2
          echo "  Windows rejects a wrong-machine DLL with ERROR_BAD_EXE_FORMAT" >&2
          echo "  before main() runs.  A same-machine provider has to be in the" >&2
          echo "  closure — check extraClosurePaths, and check that every input" >&2
          echo "  was built for the same cross target." >&2
          exit 1
        fi
        # Name the staged file after the PROVIDER, not after the import-table
        # spelling.  `dest="$out/bin/$imp"` wrote the import entry's case, so a
        # closure provider `libbar.dll` imported as `LIBBAR.DLL` arrived in the
        # bundle as `bin/LIBBAR.DLL` — and every Qt gate in this script tests
        # case-SENSITIVE globs against bin/ (`Qt6*.dll` for qt_detected, whose
        # false branch skips the plugin scan, the QML scan and qt.conf).  A Qt
        # DLL reaching bin/ only through a differently-cased import entry
        # therefore turned Qt staging off, silently.  Not hypothetical in this
        # toolchain: the real bundle's own tables carry both KERNEL32.DLL and
        # KERNEL32.dll.  Windows itself is case-insensitive, so the provider's
        # own spelling satisfies the import either way.
        dest_name="$(basename "$src")"
        dest="$stage_dir/$dest_name"
        if [ -d "$dest" ]; then
          echo "  ERROR: cannot stage $dest_name into ${stage_dir#$out/}/: a" >&2
          echo "  DIRECTORY of that name is already there.  A directory cannot" >&2
          echo "  satisfy an import, and overwriting it is not something this" >&2
          echo "  script should guess at." >&2
          exit 1
        fi
        # cp -L, never cp -a: the closure entry is very often win-dll-link.sh's
        # RELATIVE symlink into another store path, and copying it as a symlink
        # stages a link that dangles the instant the bundle is moved.
        #
        # Attributed, because `set -e` makes an unchecked `cp` end the build on
        # cp's own one-line message with no ERROR and no phase — and it does so
        # BEFORE the post-condition three lines down, so the guard that exists
        # to explain this failure could never see the commonest way it happens.
        cp -L "$src" "$dest" || {
          echo "  ERROR: could not stage $dest_name into ${stage_dir#$out/} for" >&2
          echo "  ${root#$out/}, which imports $imp.  Source:" >&2
          echo "      $src" >&2
          exit 1
        }
        chmod u+w "$dest" 2>/dev/null || true
        # The path just changed on disk, so drop any classification cached for
        # it before asking what it now is.
        unset 'pe_filetype_cache[$dest]'
        unset 'pe_arch_cache[$dest]'
        # `pe_is_pe` is part of the post-condition, not decoration: the whole
        # point of checking the provider was that a name is not a module, and a
        # copy that lands truncated or empty-but-nonzero is the same hole one
        # step later.
        if [ -L "$dest" ] || [ ! -f "$dest" ] || [ ! -s "$dest" ] || ! pe_is_pe "$dest"; then
          echo "  ERROR: staging $imp from $src produced no usable PE at $dest" >&2
          exit 1
        fi
        pe_dir_have["$stage_dir|$key"]="$dest_name"
        added=$((added + 1))
        pe_staged_total=$((pe_staged_total + 1))
        if [ "$dest_name" = "$imp" ]; then
          echo "    round $round  + $imp  <- ${root#$out/}  (from ${src%/*})"
        else
          echo "    round $round  + $dest_name  <- ${root#$out/}  (from ${src%/*};" \
               "import entry spells it $imp)"
        fi
      done < <(pe_imports "$root")
      # pe_files streams, and this loop writes into $out/bin while it does, so
      # whether a DLL staged mid-round is itself walked this round is
      # unspecified.  That is fine and is the reason for the outer loop: the
      # fixpoint, not the enumeration order, is what makes the result complete.
    done < <(pe_files)
    echo "    round $round: $roots_seen PE root(s) walked, $added DLL(s) added"
    # A floor under the fixpoint.  `roots_seen` was printed and never compared,
    # so a first round that walked NOTHING printed "0 PE root(s) walked, 0
    # DLL(s) added", broke out of the loop and reported "converged" — the
    # fixpoint declaring victory having measured nothing, which is the exact
    # failure mode every other check on this path exists to prevent.  Nothing
    # made that reachable except Phase 1c's census two phases upstream, and a
    # check in another phase is not a floor under this one.
    if [ "$round" -eq 1 ] && [ "$roots_seen" -eq 0 ]; then
      echo "  ERROR: the DLL closure sweep ($label) walked ZERO PE roots." >&2
      echo "  There is nothing in this bundle whose imports could be resolved," >&2
      echo "  so 'converged' would mean 'measured nothing'." >&2
      exit 1
    fi
    [ "$added" -eq 0 ] && break
    if [ "$round" -ge 25 ]; then
      echo "  ERROR: the DLL import closure did not reach a fixpoint in $round rounds" >&2
      exit 1
    fi
  done
  # Round 1 finding nothing means either a perfect bundle or a broken reader.
  # pe_reader_control has already ruled out the second, before any sweep ran,
  # so a zero here is a fact about the input.  Say what happened either way.
  if [ -n "$pe_app_dir" ]; then
    echo "  DLL closure sweep ($label) converged after $round round(s);" \
         "$pe_staged_total DLL(s) staged, $pe_mirrored_total mirrored into bin/, so far"
  else
    # No bin/, so mirroring is structurally impossible and its count would only
    # read as "nothing needed mirroring" rather than "there was nowhere to".
    echo "  DLL closure sweep ($label) converged after $round round(s);" \
         "$pe_staged_total DLL(s) staged beside their importers, so far"
  fi
  # Every staging decision this sweep just made was made from import tables.
  # If the reader could not read one of them, those decisions were made from an
  # empty list that meant "unreadable", not "satisfied" — so fail here, at the
  # phase that used the data, rather than letting three more phases build on it.
  pe_assert_reader_read_everything "$label"
}

# Is this closure directory a Qt plugin/QML tree for the TARGET we are
# bundling?  Off Windows: yes, unconditionally — behaviour unchanged.
#
# On Windows it matters, because the closure of a cross-compiled bundle
# legitimately contains the NATIVE qtbase as well (it is a build-time
# dependency of the cross build, and it is present: measured, 196-path closure,
# `qtbase-6.11.1` right next to `qtbase-x86_64-w64-mingw32-6.11.1`).  Its
# lib/qt-6/plugins is full of Linux .so files, and `cp -aLn` would happily
# stage them — first, since it is merged in store-path order — leaving a
# Windows bundle whose platforms/ directory contains libqxcb.so and no
# qwindows.dll.  Deciding by CONTENT rather than by store-path name is the
# only test that cannot be fooled by naming.
# Rejection by EVIDENCE, not acceptance by evidence.  v1 required the candidate
# to contain at least one *.dll, which silently dropped a pure-QML module
# package (qmldir + .qml, no plugin DLL — the normal shape of an app design
# system): no warning, no log line, and off Windows the identical package IS
# staged, so it was a Windows-only silent regression rather than parity.
#
#   contains a PE            -> accept (it is for the target)
#   contains .so/.dylib only -> reject (this is the NATIVE Qt in a cross
#                               closure, the case this predicate exists for)
#   no native binaries at all -> accept (pure QML/data; it must ship)
#
# Every decision is logged with its reason, because an invisible accept/reject
# is how a plugin tree goes missing without anyone noticing.
qt_candidate_matches_target() {
  [ "$IS_WINDOWS" = "1" ] || return 0
  local dir="$1" f found_pe=0 found_foreign=0
  while IFS= read -r f; do
    if pe_is_pe "$f"; then found_pe=1; break; fi
    case "$f" in
      *.so|*.so.*|*.dylib) found_foreign=1 ;;
    esac
    # stderr is dropped on BOTH stages: this loop breaks as soon as it sees a
    # PE, which leaves find and sort writing into a closed pipe and printing
    # "write failed: Broken pipe" from inside the success path.
  done < <(find "$dir" \( -type f -o -type l \) 2>/dev/null | sort 2>/dev/null)
  if [ "$found_pe" = "1" ]; then
    return 0
  fi
  if [ "$found_foreign" = "1" ]; then
    echo "  Rejecting Qt tree (host-format binaries, no PE — this is the native" \
         "Qt of the cross build): $dir"
    return 1
  fi
  echo "  Accepting Qt tree with no native binaries at all (pure QML/data): $dir"
  return 0
}

# Merge-copy a Qt tree into the staging directory.
#
# `cp -aLn` is deliberately error-TOLERANT here: several store paths contribute
# overlapping subtrees and `-n` turns the later ones into no-ops, which some
# coreutils report as failures.  But "tolerant" was implemented as
# `2>/dev/null || true`, which also swallowed the errors that mean a file was
# LOST — that is how a symlinked qmldir vanished while the build printed
# "verified 50 DLL(s) present" and exited 0.  Keep the tolerance; stop keeping
# the silence.
#
# The reporting is Windows-only so the Unix log stays byte-identical; the
# copy itself is unchanged on every platform.
qt_merge_copy() {
  local candidate="$1" dest="$2" what="$3"
  local err
  mkdir -p "$dest"
  err="$(mktemp)"
  cp -aLn "$candidate"/. "$dest/" 2>"$err" || true
  chmod -R u+w "$dest" 2>/dev/null || true
  if [ "$IS_WINDOWS" = "1" ] && [ -s "$err" ]; then
    echo "  $what: cp reported $(wc -l < "$err") message(s) while copying $candidate:"
    sed 's/^/    /' "$err"
  fi
  rm -f "$err"
  return 0
}

# After a merge-copy, prove every file that was supposed to arrive actually
# arrived.
#
# Over EVERY entry, not `-name '*.dll'`.  The DLL filter inspected 50 of 1651
# files (3%) of the QML tree while its comment claimed it proved "every file
# that was supposed to arrive actually arrived" — so a lost qmldir, which makes
# a QML module unloadable, was invisible and the build exited 0.
#
# Must be called BEFORE the non-runtime cleanup, which deliberately deletes
# QtTest/, QmlTime/, *.a and *.prl: checking afterwards would report those
# intentional removals as copy losses.
qt_assert_staged() {
  local dest="$1" what="$2"
  shift 2
  local cand src rel missing=0 checked=0 n empty_cands=0
  for cand in "$@"; do
    n=0
    while IFS= read -r src; do
      rel="${src#"$cand"/}"
      checked=$((checked + 1))
      n=$((n + 1))
      # `-L` is part of the test, not redundant with `-e`: cp -aL is supposed to
      # DEREFERENCE, so a symlink arriving as a symlink means it pointed
      # outside the store path and will dangle once the bundle moves.
      if [ ! -e "$dest/$rel" ] || [ -L "$dest/$rel" ]; then
        echo "  ERROR: $what: $rel did not survive the copy from $cand" >&2
        missing=$((missing + 1))
      fi
    done < <(find "$cand" \( -type f -o -type l \) 2>/dev/null)
    if [ "$n" -eq 0 ]; then
      empty_cands=$((empty_cands + 1))
      echo "  $what: $cand contributed no files"
    fi
  done
  echo "  $what: verified $checked file(s) present in ${dest#"$out"/}" \
       "($# candidate(s), $empty_cands of them empty)"
  # NOT an exit.  v1 treated zero as "a bug, not an empty input", which was only
  # true while qt_candidate_matches_target guaranteed >= 1 DLL per candidate —
  # it no longer does, and an empty tree is a legitimate input.  Whether an
  # empty RESULT is fatal is Phase 6's contract check to decide, with the whole
  # bundle in view.
  if [ "$checked" -eq 0 ]; then
    echo "  $what: nothing to verify — every accepted candidate was empty"
  fi
  if [ "$missing" -gt 0 ]; then
    echo "  ERROR: $what: $missing file(s) lost in the copy" >&2
    exit 1
  fi
}

pe_fail_on_unresolved() {
  # `${#pe_unresolved[@]}` is itself an unbound-variable error under `set -u`
  # when the associative array has never had an element assigned, so the
  # emptiness test has to be the `+x` form.  Getting this wrong fails the
  # build on the SUCCESS path, which is at least loud.
  [ -z "${pe_unresolved[*]+x}" ] && return 0
  local n
  echo ""
  echo "FAILED: ${#pe_unresolved[@]} DLL import(s) could not be resolved from the closure:"
  for n in "${!pe_unresolved[@]}"; do
    echo "  $n"
    printf '%s\n' ${pe_unresolved["$n"]} | sort -u | while IFS= read -r i; do
      [ -n "$i" ] && echo "      imported by: $i"
    done
  done
  echo ""
  echo "A PE import table carries base names only, so a missing DLL is not a"
  echo "degraded feature — it is exit 0xC0000135 (STATUS_DLL_NOT_FOUND) before"
  echo "main() runs, with no Qt message, no stderr and no output whatsoever."
  echo ""
  echo "The usual cause is that the providing store path is not in the closure:"
  echo "a PE embeds no /nix/store strings, so Nix records no reference to it and"
  echo "it never reaches closureInfo.  Add the package to the derivation's"
  echo "passthru.extraClosurePaths (mkBundle's extraClosurePaths)."
  exit 1
}

# ===========================================================================
# Phase 2 — Trace and collect shared library dependencies
# ===========================================================================
echo "Phase 2: Tracing shared library dependencies..."

declare -A visited
declare -A framework_map
framework_count=0

collect_lib() {
  local lib_path="$1"
  local lib_name
  lib_name="$(basename "$lib_path")"

  [[ -z "${visited[$lib_path]:-}" ]] || return 0
  visited[$lib_path]=1

  if is_system_lib "$lib_name"; then
    echo "  Skipping (system): $lib_name"
    return 0
  fi

  local real_path
  real_path="$(realpath "$lib_path" 2>/dev/null)" || return 0
  [ -f "$real_path" ] || return 0

  # Detect framework structure from source path (e.g. .../Foo.framework/Versions/A/Foo)
  local is_framework=0
  local fw_relpath=""
  if [[ "$lib_path" == *.framework/* ]]; then
    is_framework=1
    # Extract from the .framework component onward (e.g. QtCore.framework/Versions/A/QtCore)
    fw_relpath="${lib_path##*/lib/}"
    # Fallback: extract starting from *.framework/
    if [[ "$fw_relpath" != *.framework/* ]]; then
      fw_relpath="${lib_path#*\.framework/}"
      local fw_name_part="${lib_path%%\.framework/*}"
      fw_name_part="${fw_name_part##*/}"
      fw_relpath="${fw_name_part}.framework/${fw_relpath}"
    fi
    framework_map[$lib_name]="$fw_relpath"
    framework_count=$((framework_count + 1))
  fi

  # Host-provided libs: record framework info (above) but don't copy
  if is_host_lib "$lib_name"; then
    echo "  Skipping (host-provided): $lib_name"
    return 0
  fi

  # If the framework directory already exists (e.g. copied in Phase 1), skip the flat copy
  if [ "$is_framework" = "1" ]; then
    local fw_top="${fw_relpath%%/*}"
    if [ -d "$out/lib/$fw_top" ]; then
      # Framework already present — don't create a flat duplicate
      echo "  $lib_name (framework already bundled)"
    elif [ ! -e "$out/lib/$lib_name" ]; then
      mkdir -p "$out/lib"
      cp -a "$lib_path" "$out/lib/"
      chmod u+w "$out/lib/$lib_name" 2>/dev/null || true
      echo "  $lib_name"
    fi
  elif [ ! -e "$out/lib/$lib_name" ]; then
    mkdir -p "$out/lib"
    cp -a "$lib_path" "$out/lib/"
    if [ -L "$lib_path" ]; then
      local target_name
      target_name="$(basename "$real_path")"
      if [ ! -e "$out/lib/$target_name" ]; then
        cp -a "$real_path" "$out/lib/"
      fi
    fi
    chmod u+w "$out/lib/$lib_name" 2>/dev/null || true
    echo "  $lib_name"
  fi

  trace_deps "$real_path"
}

trace_deps() {
  local bin="$1"
  local filetype
  filetype="$(file -b "$bin" 2>/dev/null)" || return 0

  if [[ "$filetype" == *Mach-O* ]]; then
    # Collect rpath dirs for resolving @rpath/ references
    local -a rpath_dirs_macho=()
    while IFS= read -r rpath; do
      rpath_dirs_macho+=("$rpath")
    done < <(otool -l "$bin" 2>/dev/null | awk '/cmd LC_RPATH/{found=1} found && /path /{print $2; found=0}')

    while IFS= read -r line; do
      # Skip fat binary architecture headers
      [[ "$line" == *"(architecture"* ]] && continue
      dep="$(echo "$line" | sed -E 's/^[[:space:]]*([^[:space:]]+).*/\1/')"
      if [[ "$dep" == /nix/store/* ]] && [ -f "$dep" ]; then
        collect_lib "$dep"
      elif [[ "$dep" == @rpath/* ]]; then
        # Resolve @rpath/ by searching the rpath directories
        local rpath_lib="${dep#@rpath/}"
        for rdir in "${rpath_dirs_macho[@]}"; do
          if [ -f "$rdir/$rpath_lib" ]; then
            collect_lib "$rdir/$rpath_lib"
            break
          fi
        done
      fi
    done < <(otool -L "$bin" 2>/dev/null | tail -n +2)
  elif [[ "$filetype" == *ELF* ]]; then
    local rpath_val
    rpath_val="$(patchelf --print-rpath "$bin" 2>/dev/null)" || true
    local needed
    needed="$(patchelf --print-needed "$bin" 2>/dev/null)" || true

    local interp
    interp="$(patchelf --print-interpreter "$bin" 2>/dev/null)" || true
    if [[ -n "${interp:-}" && "$interp" == /nix/store/* ]] && [ -f "$interp" ]; then
      collect_lib "$interp"
    fi

    local IFS=':'
    local -a rpath_dirs
    read -ra rpath_dirs <<< "$rpath_val"
    unset IFS

    for lib_name in $needed; do
      # Nix sometimes embeds absolute store paths in DT_NEEDED; handle inline.
      if [[ "$lib_name" == /nix/store/* ]] && [ -f "$lib_name" ]; then
        collect_lib "$lib_name"
        continue
      fi
      local found=0
      for dir in "${rpath_dirs[@]}"; do
        [[ "$dir" == /nix/store/* ]] || continue
        if [ -f "$dir/$lib_name" ]; then
          collect_lib "$dir/$lib_name"
          found=1
          break
        fi
      done
      if [ "$found" = "0" ]; then
        while IFS= read -r storePath; do
          if [ -f "$storePath/lib/$lib_name" ]; then
            collect_lib "$storePath/lib/$lib_name"
            break
          fi
        done < "$CLOSURE_PATHS"
      fi
    done
  fi
}

# Windows is tested FIRST, everywhere a platform is tested, because the
# alternative has bitten this port repeatedly: a PE reaches `trace_deps`, falls
# out of its Mach-O/ELF chain through the missing `else`, and the whole phase
# becomes a silent no-op that still exits 0.
if [ "$IS_WINDOWS" = "1" ]; then
  echo "  PE: rpath tracing does not apply (an import table carries base names"
  echo "  only); resolving the DLL import closure instead."
  pe_resolve_objdump
  # The reader control runs FIRST, before the index and before any sweep.
  # Everything after it interprets an empty import list as "already satisfied";
  # this is the one place where an empty import list is interpreted as "the
  # reader is broken", and it has to come before anything relies on the other
  # reading.
  pe_reader_control
  pe_build_dll_index
  # First sweep.  It cannot be the last one — the Qt plugin and QML trees are
  # not staged until Phase 2b, and their DLLs are exactly the ones no import
  # table mentions.  But it must run BEFORE Phase 2b, because the Qt and QML
  # detection gates read bin/, and Qt6Qml*.dll / Qt6Quick*.dll only get there
  # through the UI plugin's imports.
  pe_sweep "pass 1: exe + modules + plugins"
else

if [ -d "$out/bin" ]; then
  for f in "$out"/bin/*; do
    [ -f "$f" ] || continue
    trace_deps "$f"
  done
fi

if [ -d "$out/lib" ]; then
  for f in "$out"/lib/*; do
    [ -f "$f" ] || continue
    trace_deps "$f"
  done
fi

# Trace deps of shared libraries in extra directories
for dir in "${extra_dirs[@]+"${extra_dirs[@]}"}"; do
  if [ -d "$out/$dir" ]; then
    while IFS= read -r f; do
      trace_deps "$f"
    done < <(find "$out/$dir" -type f \( -name '*.dylib' -o -name '*.so' \))
  fi
done

fi

# Fix absolute symlinks in lib/ that point into /nix/store
# Never pointed at a PE bundle: this loop DELETES links it cannot resolve, and
# on Windows every DLL lives in bin/ as a real file anyway.
if [ "$IS_WINDOWS" != "1" ] && [ -d "$out/lib" ]; then
  find "$out/lib" -type l | while IFS= read -r link; do
    target="$(readlink "$link")"
    if [[ "$target" == /nix/store/* ]]; then
      target_name="$(basename "$target")"
      if [ -e "$out/lib/$target_name" ]; then
        rm "$link"
        ln -s "$target_name" "$link"
      elif [ -f "$target" ]; then
        rm "$link"
        cp -aL "$target" "$link"
        chmod u+w "$link" 2>/dev/null || true
      fi
    fi
  done
fi

# ===========================================================================
# Phase 2b — Bundle Qt plugins (if Qt is present)
# ===========================================================================
# Qt plugins are loaded at runtime via dlopen and won't appear in the
# dependency trace. If we bundled any Qt library, search the closure for
# the plugins directory, copy it, trace plugin deps, and create qt.conf.
qt_detected=0
qt_is_host=0
# Windows FIRST.  MinGW Qt fails the `libQt*.so*` / `libQt*.dylib` glob below
# on three independent counts, any one of them fatal: the extension is .dll,
# there is no `lib` prefix (the file is literally Qt6Core.dll), and it lives in
# bin/ rather than lib/.  Because the consumer of qt_detected has no `else`
# arm, that miss used to skip the plugin scan, the QML scan AND qt.conf with no
# message at all, producing a bundle that exits 0 and cannot start.
#
# ...and the glob it was replaced with re-opened the same hole from the other
# side.  `$out/bin/Qt6*.dll` cannot match on the module shape that this branch
# added support for: a Logos module has no bin/, so the sweep stages Qt beside
# the importer in lib/, and a bundle visibly containing lib/Qt6Core.dll printed
# "no Qt libraries in this bundle" and exited 0 with the whole Windows Qt
# contract in Phase 6 never evaluated.  Look wherever the sweep is allowed to
# put things, which is anywhere in the tree, rather than at one directory.
qt_module_shape=0
if [ "$IS_WINDOWS" = "1" ]; then
  pe_resolve_app_dir
  qt_win_hit="$(find "$out" -type f \( -name 'Qt6*.dll' -o -name 'Qt5*.dll' \) -print -quit 2>/dev/null || true)"
  if [ -n "$qt_win_hit" ]; then
    qt_lib_name="$(basename "$qt_win_hit")"
    if [ -n "$pe_app_dir" ]; then
      qt_detected=1
      if is_host_lib "$qt_lib_name"; then
        qt_is_host=1
      fi
    else
      # Qt IS here, and this output is a module rather than an application.
      # Staging a plugin tree and writing qt.conf would be inventing an app
      # layout for something that gets installed into someone else's tree —
      # qt.conf, the platform plugin and the QML tree belong to the process
      # that loads this module, not to the module.  So do not pretend to check
      # a contract this output does not own; say so, loudly, instead of
      # reporting "no Qt libraries in this bundle", which was false.
      qt_module_shape=1
    fi
  fi
fi
if [ "$qt_detected" = "0" ] && [ "$framework_count" -gt 0 ]; then
  for fw in "${!framework_map[@]}"; do
    if [[ "$fw" == Qt* ]]; then
      qt_detected=1
      # Check if this Qt lib is host-provided (not bundled)
      if is_host_lib "$fw"; then
        qt_is_host=1
      fi
      break
    fi
  done
fi
# Also check for flat Qt libs (non-framework, e.g. Linux)
if [ "$qt_detected" = "0" ] && [ -d "$out/lib" ]; then
  for f in "$out"/lib/libQt*.so* "$out"/lib/libQt*.dylib; do
    if [ -e "$f" ]; then
      qt_detected=1
      qt_lib_name="$(basename "$f")"
      if is_host_lib "$qt_lib_name"; then
        qt_is_host=1
      fi
      break
    fi
  done
fi

if [ "$qt_detected" = "1" ] && [ "$qt_is_host" = "1" ]; then
  echo "Phase 2b: Skipping Qt plugin/QML bundling (Qt is host-provided)"
elif [ "$qt_detected" = "1" ]; then
  echo "Phase 2b: Bundling Qt plugins..."
  qt_plugins_found=0
  qt_accepted_candidates=()

  while IFS= read -r storePath; do
    # Look for Qt plugin directories in every closure path and merge them.
    # Different Qt modules ship plugins in separate store paths (e.g. qtbase
    # has platforms/, qtsvg has iconengines/, qtnetwork has tls/, etc.), so we
    # must not stop after the first match.
    for candidate in "$storePath/lib/qt-6/plugins" "$storePath/lib/qt-5/plugins" "$storePath/share/qt-6/plugins" "$storePath/share/qt-5/plugins" "$storePath/lib/qt6/plugins" "$storePath/lib/qt5/plugins"; do
      if [ -d "$candidate" ] && qt_candidate_matches_target "$candidate"; then
        echo "  Found Qt plugins: $candidate"
        qt_merge_copy "$candidate" "$qt_plugins_dir" "Qt plugins"
        qt_accepted_candidates+=("$candidate")
        qt_plugins_found=1
        break  # only one candidate per store path
      fi
    done
  done < "$CLOSURE_PATHS"

  if [ "$qt_plugins_found" = "1" ]; then
    # BEFORE the cleanup below, which deletes *.a / *.prl / objects-Release on
    # purpose: an assertion that runs afterwards reports every intentional
    # removal as a copy loss.  (v1 checked afterwards and got away with it only
    # because it looked at *.dll and nothing else.)
    if [ "$IS_WINDOWS" = "1" ]; then
      qt_assert_staged "$qt_plugins_dir" "Qt plugins" "${qt_accepted_candidates[@]}"
    fi
    # Remove build artifacts from plugins (static libs, build metadata).
    # MinGW's import libraries are `libfoo.dll.a`, which `*.a` already matches
    # — checked, because "unsuffixed / MSVC-shaped glob" is a recurring bug in
    # this port and `foo.lib` would NOT have been caught here.
    find "$qt_plugins_dir" \( -name '*.a' -o -name '*.prl' -o -name '*.o' \) -delete 2>/dev/null || true
    while IFS= read -r junk_dir; do
      rm -rf "$junk_dir"
    done < <(find "$qt_plugins_dir" -type d -name 'objects-Release' 2>/dev/null)
    find "$qt_plugins_dir" -type d -empty -delete 2>/dev/null || true

    if [ "$IS_WINDOWS" = "1" ]; then
      echo "  PE: plugin imports are resolved by the DLL closure sweep in Phase 2e"
    else
      # Trace deps of all plugin shared libraries
      echo "  Tracing plugin dependencies..."
      while IFS= read -r plugin; do
        trace_deps "$plugin"
      done < <(find "$qt_plugins_dir" -type f \( -name '*.dylib' -o -name '*.so' \))
    fi
  elif [ "$IS_WINDOWS" = "1" ]; then
    # Not a warning on Windows.  Without platforms/qwindows.dll the app dies
    # with "Could not find the Qt platform plugin", and the whole reason this
    # branch exists is that the previous behaviour was to exit 0 regardless.
    echo "  ERROR: Qt was detected in bin/ but no Qt plugin directory for this" >&2
    echo "  target was found anywhere in the closure.  qtbase's plugins are" >&2
    echo "  almost certainly missing from closureInfo — add it to" >&2
    echo "  extraClosurePaths." >&2
    exit 1
  else
    echo "  Warning: Qt detected but no plugins directory found in closure"
  fi

  # Bundle QML modules only when the derivation actually uses QtQml/QtQuick.
  # Non-UI derivations (e.g. using only QtCore/QtNetwork) don't need QML.
  #
  # Windows FIRST — this used to be the `else` arm of an IS_DARWIN test, so a
  # PE bundle fell into the Unix arm and its `.so` glob, and QML staging was
  # skipped even once the plugin gate above was fixed.
  #
  # win_qml_gate is defined with the other PE helpers, not here: Phase 6 has to
  # ask the same question, and a function defined inside a branch that did not
  # run does not exist.
  qml_needed=0
  if [ "$IS_WINDOWS" = "1" ]; then
    win_qml_gate && qml_needed=1
  elif [ "$IS_DARWIN" = "1" ]; then
    for fw in "${!framework_map[@]}"; do
      if [[ "$fw" == QtQml* ]] || [[ "$fw" == QtQuick* ]]; then
        qml_needed=1
        break
      fi
    done
  else
    for f in "$out"/lib/libQt*Qml*.so* "$out"/lib/libQt*Quick*.so*; do
      if [ -e "$f" ]; then
        qml_needed=1
        break
      fi
    done
  fi

  qt_qml_found=0
  qml_accepted_candidates=()

  # The QML staging pass, as a function, so Phase 2e can run it a second time
  # if the DLL sweep turns the gate above from 0 to 1 after the fact.  On every
  # non-Windows platform this is called exactly once, from exactly where the
  # inline block used to be, and emits exactly what it used to emit.
  stage_qml_modules() {
    echo "  Bundling QML modules..."
    while IFS= read -r storePath; do
      for candidate in "$storePath/lib/qt-6/qml" "$storePath/lib/qt-5/qml" "$storePath/share/qt-6/qml" "$storePath/share/qt-5/qml" "$storePath/lib/qt6/qml" "$storePath/lib/qt5/qml"; do
        if [ -d "$candidate" ] && qt_candidate_matches_target "$candidate"; then
          echo "  Found QML modules: $candidate"
          # Merge contents (multiple store paths may contribute different modules)
          qt_merge_copy "$candidate" "$qt_qml_dir" "QML modules"
          qml_accepted_candidates+=("$candidate")
          qt_qml_found=1
        fi
      done
    done < "$CLOSURE_PATHS"

    if [ "$IS_WINDOWS" = "1" ] && [ "$qt_qml_found" = "0" ]; then
      echo "  ERROR: QtQuick/QtQml DLLs are in bin/, so this bundle renders QML," >&2
      echo "  but no QML module directory for this target was found in the" >&2
      echo "  closure.  qtdeclarative is missing from closureInfo — add it to" >&2
      echo "  extraClosurePaths.  (A PE embeds no store paths, so nothing pulls" >&2
      echo "  qtdeclarative into the closure on its own.)" >&2
      exit 1
    fi

    # Verify the merge-copy BEFORE the cleanup below, which deliberately
    # deletes QtTest/, QmlTime/ and Qt/test/ — checking afterwards would flag
    # those intentional removals as copy losses.
    if [ "$IS_WINDOWS" = "1" ] && [ "$qt_qml_found" = "1" ]; then
      qt_assert_staged "$qt_qml_dir" "QML modules" "${qml_accepted_candidates[@]}"
    fi

    if [ "$qt_qml_found" = "1" ]; then
      # Remove non-runtime files from QML modules to reduce bundle size:
      #   - designer/ dirs: Qt Designer metadata and images (large)
      #   - objects-Release/ dirs: CMake build artifacts
      #   - Qt/test/: test utilities
      #   - QtTest/: test framework
      #   - QmlTime/: testing helper
      #   - *.a, *.prl: static libraries and build metadata
      echo "  Cleaning non-runtime QML files..."
      qml_base="$qt_qml_dir"
      qml_cleaned=0
      # Remove directories that are never needed at runtime
      for dir in \
        "$qml_base/QtTest" \
        "$qml_base/QmlTime" \
        "$qml_base/Qt/test" \
      ; do
        if [ -d "$dir" ]; then
          rm -rf "$dir"
          qml_cleaned=$((qml_cleaned + 1))
        fi
      done
      # Remove designer/ and objects-Release/ dirs anywhere in the tree
      while IFS= read -r junk_dir; do
        rm -rf "$junk_dir"
        qml_cleaned=$((qml_cleaned + 1))
      done < <(find "$qml_base" -type d \( -name 'designer' -o -name 'objects-Release' \) 2>/dev/null)
      # Remove static libs and build metadata (not needed at runtime)
      find "$qml_base" \( -name '*.a' -o -name '*.prl' -o -name '*.o' \) -delete 2>/dev/null || true
      # Remove empty directories left over from cleanup
      find "$qml_base" -type d -empty -delete 2>/dev/null || true
      echo "  Removed $qml_cleaned non-runtime directories"

      if [ "$IS_WINDOWS" = "1" ]; then
        echo "  PE: QML module imports are resolved by the DLL closure sweep in Phase 2e"
      else
        # Trace deps of shared libraries inside QML modules
        echo "  Tracing QML module dependencies..."
        while IFS= read -r qml_lib; do
          trace_deps "$qml_lib"
        done < <(find "$qt_qml_dir" -type f \( -name '*.dylib' -o -name '*.so' \))
      fi
    fi

    # Symlink app-shipped QML modules (in lib/ outside lib/qt/) into the
    # QML import path so they are discoverable alongside Qt's own modules.
    # QML modules are identified by the presence of a qmldir file.
    if [ -d "$qt_qml_dir" ] && [ -d "$out/lib" ]; then
      while IFS= read -r qmldir; do
        mod_dir="$(dirname "$qmldir")"
        # Relative path from $out/lib, e.g. "Logos/Theme"
        rel="${mod_dir#$out/lib/}"
        # Skip anything already under the staged Qt tree
        [[ "$rel" == "$qt_stage"/* ]] && continue
        if [ ! -e "$qt_qml_dir/$rel" ]; then
          echo "  Symlinking app QML module: $rel"
          link_parent="$(dirname "$qt_qml_dir/$rel")"
          mkdir -p "$link_parent"
          target="$(realpath --relative-to="$link_parent" "$mod_dir")"
          ln -sf "$target" "$qt_qml_dir/$rel"
        fi
      done < <(find "$out/lib" -name 'qmldir' -not -path "*/$qt_stage/*")
    fi
  }

  if [ "$qml_needed" = "1" ]; then
    stage_qml_modules
  else
    echo "  Skipping QML bundling (no QtQml/QtQuick libraries detected)"
  fi

  # Create qt.conf so Qt can find plugins and QML modules relative to the binary.
  # LibraryExecutables / Data / Translations are set explicitly because the
  # compile-time defaults in some Qt builds (notably nixpkgs qt6) use paths
  # like "libexec/qt6", while our bundle lays things out at the Qt 6 defaults
  # ("libexec", ".", "translations") relative to Prefix.  QtWebEngine looks up
  # QtWebEngineProcess via LibraryExecutablesPath and its .pak/icudtl.dat via
  # DataPath + "/resources", so getting these wrong breaks the webview plugin.
  if [ "$IS_WINDOWS" = "1" ]; then
    # DEFERRED to Phase 2f, on purpose.  Written here, qt.conf describes the
    # tree that is predicted to exist rather than the tree that does: v1 emitted
    # `Qml2Imports = lib/qt-6/qml` pointing at a directory that was never
    # created, because the QML gate was decided before the sweep that stages the
    # very DLLs the gate tests for.
    :
  elif [ -d "$out/bin" ]; then
    echo "  Creating qt.conf..."
    cat > "$out/bin/qt.conf" <<QTCONF
[Paths]
Prefix = ..
Plugins = lib/qt/plugins
LibraryExecutables = libexec
Data = .
Translations = translations
$([ "$qt_qml_found" = "1" ] && echo "QmlImports = lib/qt/qml")
QTCONF
  fi
elif [ "$IS_WINDOWS" = "1" ]; then
  # The missing arm.  Until now qt_detected=0 skipped the plugin scan, the QML
  # scan and qt.conf in silence — which is exactly how a Windows bundle came
  # out with an empty lib/, no qt.conf and no qwindows.dll while exiting 0.
  # A non-Qt bundle reaching here is perfectly normal, so this is a statement,
  # not a warning; the point is that the skip is now visible in the log.
  #
  # Windows-only: on Unix the skip has never produced a broken bundle, and an
  # extra line there is a real (if small) change to a log this branch is
  # otherwise required to leave byte-identical.
  if [ "$qt_module_shape" = "1" ]; then
    echo "Phase 2b: Qt IS present in this bundle ($qt_lib_name), but the output" \
         "has no application directory — it is a module, not an app."
    echo "  qt.conf, the platform plugin and the QML tree belong to the process" \
         "that loads this module, so they are NOT staged and NOT checked here."
    echo "  If this output was meant to be an application, its bin/ is missing" \
         "and the Qt runtime contract has gone unverified."
  else
    echo "Phase 2b: Skipping Qt plugin/QML bundling (no Qt libraries in this bundle)"
  fi
fi

# ===========================================================================
# Phase 2e — Windows: drive the DLL import closure to a fixpoint
# ===========================================================================
# Pass 1 ran before Phase 2b and could only see the .exe, the modules and the
# app plugins.  The Qt plugin and QML trees are staged now, and they are the
# part no import table can reveal: they are LoadLibrary'd, so nothing links to
# them — and neither does anything link to what THEY need.  Qt6QmlCore is the
# canonical example: absent from every import table in the bundle, reachable
# only through a QML plugin, and its absence is a silent 0xC0000135.
if [ "$IS_WINDOWS" = "1" ]; then
  echo "Phase 2e: Completing the PE import closure over the staged Qt tree..."
  pe_sweep "pass 2: + Qt plugins and QML modules"

  # The QML staging DECISION is itself a fixpoint, not a one-shot test.
  #
  # The gate reads bin/Qt6Qml*.dll / Qt6Quick*.dll, and the sweep above is what
  # puts those DLLs in bin/ — qtdeclarative's qmltooling plugins are staged
  # unconditionally by Phase 2b and import Qt6Qml.  So a bundle could log
  # "Skipping QML bundling (no QtQml/QtQuick libraries detected)", then acquire
  # Qt6Qml.dll, Qt6Quick.dll, Qt6QmlModels.dll, Qt6QmlMeta.dll and
  # Qt6QmlWorkerScript.dll one phase later, and ship a qt.conf whose
  # Qml2Imports pointed at a directory that was never created.  Exit 0.
  #
  # Re-evaluating here removes the order dependence: whatever the enumeration
  # order was, the answer at the end is the same.  Bounded and loud, because an
  # unbounded restaging loop would be a worse bug than the one it fixes.
  qml_restage_round=0
  while [ "$qt_detected" = "1" ] && [ "$qt_is_host" != "1" ] \
        && [ "${qt_qml_found:-0}" = "0" ] && win_qml_gate; do
    qml_restage_round=$((qml_restage_round + 1))
    if [ "$qml_restage_round" -gt 3 ]; then
      echo "  ERROR: the QML staging decision did not stabilise in" \
           "$qml_restage_round rounds" >&2
      exit 1
    fi
    echo "  The DLL sweep put QtQml/QtQuick in bin/ after the QML gate was" \
         "evaluated; staging QML modules now (round $qml_restage_round)"
    qml_needed=1
    stage_qml_modules
    pe_sweep "pass $((2 + qml_restage_round)): + QML modules staged after the gate flipped"
  done

  # The memo in pe_resolve_app_dir latches on first call, justified by "Phase 1
  # has run by the time the first sweep does, so bin/ either exists or never
  # will".  bundle.sh has exactly one `mkdir -p "$out/bin"`, in Phase 1, so that
  # holds today — and nothing enforces it.  If a later phase ever creates bin/,
  # staging silently keeps going beside importers while the log keeps saying
  # there is no bin/: a silent success with no assertion behind it.  Assert it
  # instead of trusting the comment.
  if [ -z "$pe_app_dir" ] && [ -d "$out/bin" ]; then
    echo "  ERROR: bin/ did not exist when the DLL sweep resolved the staging" >&2
    echo "  destination, but it exists now, so everything was staged beside its" >&2
    echo "  importer on the strength of a fact that stopped being true." >&2
    echo "  Whatever phase created $out/bin has to run before Phase 2e." >&2
    exit 1
  fi
  pe_fail_on_unresolved
  # A statement, not an exit.  v1 exited here on the grounds that "a real Qt
  # bundle always needs at least one", which is true of a real Qt bundle and
  # false of the input: a self-contained executable whose imports are all system
  # DLLs stages nothing and is correct.  The reader control in Phase 2 is what
  # makes this zero trustworthy — it proved the reader reads before any of this
  # ran — so a zero here is a fact about the bundle.
  if [ "$pe_staged_total" -eq 0 ]; then
    # Two arms, for the same reason the sweep-converged line above has two:
    # this sentence enumerates DISTINCT places, and substituting
    # $pe_stage_label into it collapses the first onto the second when there
    # is no bin/ ("satisfied from each importer's own directory, from the
    # importer's own directory, ..."), naming one place twice and silently
    # dropping the fact that there is no application directory at all.
    if [ -n "$pe_app_dir" ]; then
      echo "  DLL closure complete: nothing needed staging — every import was" \
           "already satisfied from bin/, from the importer's own directory, or" \
           "by a Windows system DLL."
    else
      echo "  DLL closure complete: nothing needed staging — this output has no" \
           "bin/, so every import was already satisfied from the importer's own" \
           "directory or by a Windows system DLL."
    fi
  else
    echo "  DLL closure complete: $pe_staged_total DLL(s) staged into $pe_stage_label"
  fi
  if [ -e "$out/bin/Qt6WebEngineCore.dll" ]; then
    echo "  WARNING: Qt6WebEngineCore.dll is in this bundle, but Phase 2d's" >&2
    echo "  QtWebEngine runtime-data staging has no Windows detection arm, so" >&2
    echo "  QtWebEngineProcess.exe, resources/ and the locale .pak files are NOT" >&2
    echo "  bundled.  The webview will fail at runtime." >&2
  fi

  # =========================================================================
  # Phase 2f — Windows: qt.conf, written last
  # =========================================================================
  # After the final sweep and after any late QML staging, so it describes the
  # tree that exists.
  #
  # Every key is named explicitly, and that is not tidiness.  Measured on real
  # Windows: setting Prefix alone makes Qt report
  #     Could not find the Qt platform plugin "windows" in ""
  # — an empty search path, not a wrong one.  Libraries and Binaries both point
  # at bin/ because MinGW puts every DLL there, Qt's own included.  Imports and
  # Qml2Imports are both set: Qt 6 reads Qml2Imports, but the bundle should not
  # depend on which spelling a given build honours.
  #
  # The two QML keys are emitted only when QML modules were actually staged,
  # exactly as the Unix arm above already does.  Writing them unconditionally
  # contradicted the stated reason for deferring qt.conf to this phase: a Qt
  # Widgets-only Windows bundle got a qt.conf naming `lib/qt-6/qml`, which that
  # bundle does not have.  Harmless at runtime (an absent import path is simply
  # empty) and invisible to Phase 6, whose converse check only fires when
  # bin/Qt6Quick.dll is present — which is precisely why it is worth not doing.
  if [ "$qt_detected" = "1" ] && [ "$qt_is_host" != "1" ] && [ -d "$out/bin" ]; then
    echo "Phase 2f: Creating qt.conf..."
    {
      echo "[Paths]"
      echo "Prefix = .."
      echo "Libraries = bin"
      echo "Binaries = bin"
      echo "Plugins = lib/$qt_stage/plugins"
      if [ "${qt_qml_found:-0}" = "1" ]; then
        echo "Imports = lib/$qt_stage/qml"
        echo "Qml2Imports = lib/$qt_stage/qml"
      fi
    } > "$out/bin/qt.conf"
    echo "  qt.conf keys: Prefix, Libraries, Binaries, Plugins$(
      [ "${qt_qml_found:-0}" = "1" ] && echo ", Imports, Qml2Imports")"
  fi
fi

# ===========================================================================
# Phase 2c — Bundle xkeyboard-config data (if libxkbcommon is present)
# ===========================================================================
# libxkbcommon is compiled with DFLT_XKB_CONFIG_ROOT pointing at a /nix/store
# xkeyboard-config path that won't exist at runtime.  Without this data the
# context init returns NULL, and Qt Wayland's keymap dispatch dereferences it
# and segfaults.  Copy the data into share/X11/xkb so consumers can point
# XKB_CONFIG_ROOT at it.
xkb_detected=0
# Windows guard is explicit rather than left to the `.so`/`.dylib` glob failing
# to match: relying on a glob to miss is how a phase becomes accidentally
# correct, and stays that way only until someone widens the glob.
if [ "$IS_WINDOWS" != "1" ] && [ -d "$out/lib" ]; then
  for f in "$out"/lib/libxkbcommon.so* "$out"/lib/libxkbcommon*.dylib; do
    if [ -e "$f" ]; then
      xkb_detected=1
      break
    fi
  done
fi

if [ "$xkb_detected" = "1" ]; then
  echo "Phase 2c: Bundling xkeyboard-config data..."
  xkb_found=0
  while IFS= read -r storePath; do
    for candidate in "$storePath/etc/X11/xkb" "$storePath/share/X11/xkb"; do
      if [ -d "$candidate" ]; then
        echo "  Found xkb data: $candidate"
        mkdir -p "$out/share/X11/xkb"
        cp -aLn "$candidate"/. "$out/share/X11/xkb/" 2>/dev/null || true
        chmod -R u+w "$out/share/X11/xkb" 2>/dev/null || true
        xkb_found=1
      fi
    done
  done < "$CLOSURE_PATHS"
  if [ "$xkb_found" = "0" ]; then
    echo "  Warning: libxkbcommon bundled but no xkeyboard-config data found in closure"
  fi
fi

# ===========================================================================
# Phase 2d — Bundle QtWebEngine runtime data (if QtWebEngineCore is present)
# ===========================================================================
# QtWebEngine needs three sets of runtime files that live outside lib/ and
# lib/qt/plugins, so Phase 1/2/2b don't pick them up:
#   - libexec/QtWebEngineProcess: the sandboxed helper process (forked per webview)
#   - resources/*.pak + icudtl.dat: Chromium resource bundles and ICU data
#   - translations/qtwebengine_locales/*.pak: localized strings
# Without the helper binary in particular, QtWebView::initialize() fails and
# the webview plugin registry reports "No WebView plug-in found!".
# Qt locates them via qt.conf's Prefix (libexec, resources, translations are
# Qt's default LibraryExecutables / Data / Translations paths).
webengine_detected=0
if [ "$framework_count" -gt 0 ]; then
  for fw in "${!framework_map[@]}"; do
    if [[ "$fw" == QtWebEngineCore* ]]; then
      webengine_detected=1
      break
    fi
  done
fi
if [ "$webengine_detected" = "0" ] && [ -d "$out/lib" ]; then
  for f in "$out"/lib/libQt*WebEngineCore*.so* "$out"/lib/libQt*WebEngineCore*.dylib; do
    if [ -e "$f" ]; then
      webengine_detected=1
      break
    fi
  done
fi

if [ "$webengine_detected" = "1" ]; then
  echo "Phase 2d: Bundling QtWebEngine runtime data..."
  webengine_process_found=0
  webengine_resources_found=0
  webengine_locales_found=0
  while IFS= read -r storePath; do
    # QtWebEngineProcess helper binary
    for candidate in \
      "$storePath/libexec/QtWebEngineProcess" \
      "$storePath/lib/qt-6/libexec/QtWebEngineProcess" \
      "$storePath/lib/qt-5/libexec/QtWebEngineProcess" \
      "$storePath/Library/QtWebEngineCore.framework/Helpers/QtWebEngineProcess.app/Contents/MacOS/QtWebEngineProcess" \
      "$storePath/lib/QtWebEngineCore.framework/Helpers/QtWebEngineProcess.app/Contents/MacOS/QtWebEngineProcess" \
    ; do
      if [ -f "$candidate" ]; then
        echo "  Found QtWebEngineProcess: $candidate"
        mkdir -p "$out/libexec"
        if [ ! -e "$out/libexec/QtWebEngineProcess" ]; then
          cp -aL "$candidate" "$out/libexec/QtWebEngineProcess"
          chmod u+w "$out/libexec/QtWebEngineProcess" 2>/dev/null || true
        fi
        webengine_process_found=1
        break
      fi
    done
    # Resources (.pak files + icudtl.dat).  Heuristic: directory must contain
    # icudtl.dat or a qtwebengine_*.pak to avoid copying unrelated resources/.
    for candidate in \
      "$storePath/resources" \
      "$storePath/share/qt-6/resources" \
      "$storePath/share/qt-5/resources" \
      "$storePath/lib/qt-6/resources" \
      "$storePath/lib/qt-5/resources" \
    ; do
      if [ -d "$candidate" ]; then
        if [ -f "$candidate/icudtl.dat" ] || ls "$candidate"/qtwebengine*.pak >/dev/null 2>&1; then
          echo "  Found QtWebEngine resources: $candidate"
          mkdir -p "$out/resources"
          cp -aLn "$candidate"/. "$out/resources/" 2>/dev/null || true
          chmod -R u+w "$out/resources" 2>/dev/null || true
          webengine_resources_found=1
        fi
      fi
    done
    # Locales
    for candidate in \
      "$storePath/translations/qtwebengine_locales" \
      "$storePath/share/qt-6/translations/qtwebengine_locales" \
      "$storePath/share/qt-5/translations/qtwebengine_locales" \
      "$storePath/lib/qt-6/translations/qtwebengine_locales" \
      "$storePath/lib/qt-5/translations/qtwebengine_locales" \
    ; do
      if [ -d "$candidate" ]; then
        echo "  Found QtWebEngine locales: $candidate"
        mkdir -p "$out/translations/qtwebengine_locales"
        cp -aLn "$candidate"/. "$out/translations/qtwebengine_locales/" 2>/dev/null || true
        chmod -R u+w "$out/translations" 2>/dev/null || true
        webengine_locales_found=1
      fi
    done
  done < "$CLOSURE_PATHS"

  if [ "$webengine_process_found" = "0" ]; then
    echo "  Warning: QtWebEngineCore bundled but QtWebEngineProcess not found in closure"
  fi
  if [ "$webengine_resources_found" = "0" ]; then
    echo "  Warning: QtWebEngineCore bundled but resources (.pak/icudtl.dat) not found in closure"
  fi
  if [ "$webengine_locales_found" = "0" ]; then
    echo "  Warning: QtWebEngineCore bundled but locales not found in closure"
  fi

  # Trace QtWebEngineProcess deps so its libraries get bundled and patched.
  # Phase 3 will then rewrite its interpreter and rpath like any other ELF.
  if [ -f "$out/libexec/QtWebEngineProcess" ]; then
    echo "  Tracing QtWebEngineProcess dependencies..."
    trace_deps "$out/libexec/QtWebEngineProcess"
  fi
fi

# Restructure framework libraries into proper .framework directory layout.
# This must run after all dependency tracing (Phase 2, 2b, extra dirs) so that
# every framework collected as a flat file gets restructured.
if [ "$IS_DARWIN" = "1" ] && [ "$framework_count" -gt 0 ]; then
  echo "  Restructuring frameworks..."
  for fw_basename in "${!framework_map[@]}"; do
    fw_relpath="${framework_map[$fw_basename]}"
    # Only restructure if the file exists as a flat file in lib/
    if [ -f "$out/lib/$fw_basename" ] && [ ! -d "$out/lib/${fw_relpath%%/*}" ]; then
      echo "  Restructuring framework: $fw_basename -> $fw_relpath"
      fw_dir="$(dirname "$fw_relpath")"
      mkdir -p "$out/lib/$fw_dir"
      mv "$out/lib/$fw_basename" "$out/lib/$fw_relpath"
      # Create standard framework symlinks (Versions/Current -> <version>)
      fw_top="${fw_relpath%%/*}"
      versions_dir="${fw_relpath#*/}"  # e.g. Versions/A/QtCore
      version_name="${versions_dir#Versions/}"
      version_name="${version_name%%/*}"  # e.g. A
      ln -sf "$version_name" "$out/lib/$fw_top/Versions/Current"
      ln -sf "Versions/Current/$fw_basename" "$out/lib/$fw_top/$fw_basename"
    fi
  done
fi

# ===========================================================================
# Phase 3 — Rewrite dynamic linking references (all Mach-O/ELF under $out)
# ===========================================================================
echo "Phase 3: Rewriting dynamic linking references..."

loader_path_to_lib() {
  local file_dir="$1"
  realpath --relative-to="$file_dir" "$out/lib"
}

# Map a Nix-built library name to its macOS system path.
# Strips minor/patch versions: libc++.1.0.dylib → /usr/lib/libc++.1.dylib
# Leaves non-numeric suffixes alone: libSystem.B.dylib → /usr/lib/libSystem.B.dylib
macos_system_lib_path() {
  local lib_name="$1"
  local sys_name
  sys_name="$(echo "$lib_name" | sed -E 's/(\.[0-9]+)\.[0-9.]+\.dylib$/\1.dylib/')"
  echo "/usr/lib/$sys_name"
}

# Windows first.  Not "also skip it" — first.  Until this arm existed a PE
# bundle took the `else` below, the ELF arm, and ran patchelf --set-rpath /
# --replace-needed / --set-interpreter over files with no such structures; the
# `file -b` guard inside made every one a no-op, so the phase announced itself
# and did nothing.  A PE genuinely needs none of it: an import table carries
# DLL base names only (no store paths to rewrite — verified, zero /nix/store
# strings), and Windows searches the executable's own directory first, which is
# where Phase 2e has just put everything.
if [ "$IS_WINDOWS" = "1" ]; then

  echo "  Skipped: a PE has no rpaths, no install names and no interpreter."
  pe_resolve_app_dir
  echo "  Its imports are base names resolved from $pe_stage_label, which Phase 2e filled."

elif [ "$IS_DARWIN" = "1" ]; then

  rewrite_macho() {
    local f="$1"
    local f_dir
    f_dir="$(dirname "$f")"
    local rel_to_lib
    rel_to_lib="$(loader_path_to_lib "$f_dir")"
    local lib_prefix="@loader_path/$rel_to_lib"

    otool -L "$f" 2>/dev/null | tail -n +2 | while IFS= read -r line; do
      # Skip fat binary architecture headers (e.g. "/path/to/lib (architecture arm64):")
      [[ "$line" == *"(architecture"* ]] && continue
      dep="$(echo "$line" | sed -E 's/^[[:space:]]*([^[:space:]]+).*/\1/')"
      if [[ "$dep" == /nix/store/* ]]; then
        lib_name="$(basename "$dep")"
        if is_host_lib "$lib_name"; then
          # Host-provided lib — rewrite to @rpath/ so the host app resolves it
          if [[ -n "${framework_map[$lib_name]:-}" ]]; then
            install_name_tool -change "$dep" "@rpath/${framework_map[$lib_name]}" "$f" 2>/dev/null || \
              echo "  Warning: install_name_tool -change failed for $dep in $f"
          else
            install_name_tool -change "$dep" "@rpath/$lib_name" "$f" 2>/dev/null || \
              echo "  Warning: install_name_tool -change failed for $dep in $f"
          fi
        elif [[ -n "${framework_map[$lib_name]:-}" ]]; then
          # Framework lib — rewrite to @rpath/ so rpath resolves it
          local fw_rpath="@rpath/${framework_map[$lib_name]}"
          install_name_tool -change "$dep" "$fw_rpath" "$f" 2>/dev/null || \
            echo "  Warning: install_name_tool -change failed for $dep in $f"
        elif [ -f "$out/lib/$lib_name" ] || [ -L "$out/lib/$lib_name" ]; then
          install_name_tool -change "$dep" "$lib_prefix/$lib_name" "$f" 2>/dev/null || \
            echo "  Warning: install_name_tool -change failed for $dep in $f"
        elif is_system_lib "$lib_name"; then
          # System library — rewrite to /usr/lib/ (strip minor version)
          local sys_path
          sys_path="$(macos_system_lib_path "$lib_name")"
          install_name_tool -change "$dep" "$sys_path" "$f" 2>/dev/null || \
            echo "  Warning: install_name_tool -change failed for $dep in $f"
        fi
      elif [[ "$dep" == @rpath/* ]]; then
        local rpath_suffix="${dep#@rpath/}"
        lib_name="$(basename "$dep")"
        if is_host_lib "$lib_name"; then
          : # Host-provided — already an @rpath/ reference, leave as-is
        elif [[ "$rpath_suffix" == *.framework/* ]]; then
          # Framework reference — keep @rpath/ intact if framework dir exists
          local fw_top="${rpath_suffix%%/*}"
          if [ -d "$out/lib/$fw_top" ]; then
            : # skip — rpath will resolve this
          else
            # Framework not restructured, rewrite to flat path
            if [ -f "$out/lib/$lib_name" ] || [ -L "$out/lib/$lib_name" ]; then
              install_name_tool -change "$dep" "$lib_prefix/$lib_name" "$f" 2>/dev/null || \
                echo "  Warning: install_name_tool -change failed for $dep in $f"
            fi
          fi
        else
          # Non-framework @rpath/ reference — rewrite to flat lib/ if we have the lib
          if [ -f "$out/lib/$lib_name" ] || [ -L "$out/lib/$lib_name" ]; then
            install_name_tool -change "$dep" "$lib_prefix/$lib_name" "$f" 2>/dev/null || \
              echo "  Warning: install_name_tool -change failed for $dep in $f"
          fi
        fi
      elif ! is_portable_ref "$dep"; then
        # Non-portable absolute path (e.g. build dir leak) — rewrite if we have the lib
        lib_name="$(basename "$dep")"
        if [ -f "$out/lib/$lib_name" ] || [ -L "$out/lib/$lib_name" ]; then
          install_name_tool -change "$dep" "$lib_prefix/$lib_name" "$f" 2>/dev/null || \
            echo "  Warning: install_name_tool -change failed for $dep in $f"
        fi
      fi
    done

    # Fix install name
    local current_id
    current_id="$(otool -D "$f" 2>/dev/null | tail -n +2 | head -1 | xargs)" || true
    if [[ -z "$current_id" ]]; then
      # otool -D returned nothing (e.g. MH_BUNDLE); check first otool -L entry
      current_id="$(otool -L "$f" 2>/dev/null | sed -n '2p' | sed -E 's/^[[:space:]]*([^[:space:]]+).*/\1/')" || true
    fi
    if [[ -n "$current_id" ]]; then
      local id_name
      id_name="$(basename "$current_id")"
      local needs_rewrite=0
      if ! is_portable_ref "$current_id"; then
        needs_rewrite=1
      elif [[ "$current_id" == @rpath/* ]]; then
        local id_rpath_suffix="${current_id#@rpath/}"
        if [[ "$id_rpath_suffix" == *.framework/* ]]; then
          # Framework install name — keep if framework dir exists
          local id_fw_top="${id_rpath_suffix%%/*}"
          if [ ! -d "$out/lib/$id_fw_top" ]; then
            needs_rewrite=1
          fi
        elif [ -f "$out/lib/$id_name" ] || [ -L "$out/lib/$id_name" ]; then
          needs_rewrite=1
        fi
      fi
      if [ "$needs_rewrite" = "1" ]; then
        if is_host_lib "$id_name"; then
          # Host-provided lib — set install name to @rpath/
          if [[ -n "${framework_map[$id_name]:-}" ]]; then
            install_name_tool -id "@rpath/${framework_map[$id_name]}" "$f" 2>/dev/null || \
              echo "  Warning: install_name_tool -id failed for $f"
          else
            install_name_tool -id "@rpath/$id_name" "$f" 2>/dev/null || \
              echo "  Warning: install_name_tool -id failed for $f"
          fi
        elif is_system_lib "$id_name"; then
          local sys_id_path
          sys_id_path="$(macos_system_lib_path "$id_name")"
          install_name_tool -id "$sys_id_path" "$f" 2>/dev/null || \
            echo "  Warning: install_name_tool -id failed for $f"
        elif [[ -n "${framework_map[$id_name]:-}" ]]; then
          # Framework lib — set install name to @rpath/Foo.framework/Versions/A/Foo
          install_name_tool -id "@rpath/${framework_map[$id_name]}" "$f" 2>/dev/null || \
            echo "  Warning: install_name_tool -id failed for $f"
        else
          install_name_tool -id "$lib_prefix/$id_name" "$f" 2>/dev/null || \
            echo "  Warning: install_name_tool -id failed for $f"
        fi
      fi
    fi

    # Delete all existing rpaths (they point to build dirs or /nix/store)
    otool -l "$f" 2>/dev/null | awk '/cmd LC_RPATH/{found=1} found && /path /{print $2; found=0}' | while IFS= read -r rpath; do
      install_name_tool -delete_rpath "$rpath" "$f" 2>/dev/null || true
    done

    # Add two rpath entries: same-dir first (@loader_path), then $out/lib.
    # The @loader_path entry lets binaries outside $out/lib find sibling
    # companion libraries co-located with them (e.g. module plugins and
    # their companion .dylib files staged together in $out/modules/<name>/).
    # Without it, a plugin with `@rpath/libfoo.dylib` references would only
    # search $out/lib and fail to find a sibling libfoo.dylib.
    install_name_tool -add_rpath "@loader_path" "$f" 2>/dev/null || true
    install_name_tool -add_rpath "$lib_prefix" "$f" 2>/dev/null || true
  }

  find "$out" -type f | while IFS= read -r f; do
    filetype="$(file -b "$f" 2>/dev/null)" || continue
    [[ "$filetype" == *Mach-O* ]] || continue
    echo "  ${f#$out/}"
    rewrite_macho "$f"
  done

else

  # Map an ELF's own machine type to the dynamic loader path its psABI
  # mandates.  Every glibc distro puts the loader exactly there — it is not a
  # packaging convention but part of the ABI, so a binary built anywhere can
  # name it and be run anywhere.  Swept and confirmed present on ubuntu
  # 16.04/18.04/20.04/22.04, debian 9/10/11, centos 7, rocky 8, fedora
  # 34/latest, opensuse leap and archlinux, on both architectures.  (Only musl
  # distros such as alpine lack it, and glibc binaries can't run there anyway.)
  #
  # The two paths deliberately do NOT rhyme, and the next reader's instinct
  # will be to "simplify" them to a single /lib64 prefix.  Don't:
  # /lib64/ld-linux-aarch64.so.1 does not exist on current Fedora or openSUSE,
  # so a /lib64 prefix for both arches silently breaks every arm64 bundle.
  # Likewise /lib/ld-linux-x86-64.so.2 is missing on 10 of those 11 x86_64
  # images.  The prefix is per-architecture and must stay that way.
  #
  # We read the machine out of the ELF header rather than assuming the
  # builder's own architecture, because a bundle can in principle be
  # cross-built.  e_machine is a 2-byte field at offset 0x12; both machines we
  # recognise are little-endian, so the low byte comes first.
  psabi_interpreter() {
    local machine elfclass
    machine="$(od -An -tx1 -j18 -N2 "$1" 2>/dev/null | tr -d ' \n')"
    # EI_CLASS (offset 0x04): 01 = 32-bit, 02 = 64-bit.  It matters because
    # x32 shares EM_X86_64 with plain x86-64 while being a 32-bit object; it
    # needs /libx32/ld-linux-x32.so.2 and would crash on the 64-bit loader.
    # We don't claim an x32 path (unverified), we just decline to guess.
    elfclass="$(od -An -tx1 -j4 -N1 "$1" 2>/dev/null | tr -d ' \n')"
    case "$machine" in
      3e00) [ "$elfclass" = "02" ] || return 1
            echo "/lib64/ld-linux-x86-64.so.2" ;; # EM_X86_64, 64-bit
      b700) [ "$elfclass" = "02" ] || return 1
            echo "/lib/ld-linux-aarch64.so.1"  ;; # EM_AARCH64, 64-bit
      # Any other architecture: we have no VERIFIED psABI path, so return
      # nothing and let the caller keep the previous best-effort behaviour
      # rather than guess.  The question is settled only for the two arches
      # above — i386, armhf, riscv64 and s390x happen to match the old
      # /lib/<name> fallback, but ppc64le does not (its psABI is
      # /lib64/ld64.so.2), so none of them are claimed here.
      *) return 1 ;;
    esac
  }

  find "$out" -type f | while IFS= read -r f; do
    filetype="$(file -b "$f" 2>/dev/null)" || continue
    [[ "$filetype" == *ELF* ]] || continue
    echo "  ${f#$out/}"

    f_dir="$(dirname "$f")"
    rel_to_lib="$(loader_path_to_lib "$f_dir")"

    # Set rpath to: same-dir first, then $out/lib.
    # The same-dir entry ($ORIGIN) lets binaries outside $out/lib find sibling
    # companion libraries co-located with them.  Example: module plugins at
    # $out/modules/<name>/<name>_plugin.so ship their companion .so files in
    # the same module directory — without $ORIGIN the linker only checks
    # $out/lib and fails with "cannot open shared object file".
    # When $f lives in $out/lib itself, $rel_to_lib is "." so the two entries
    # resolve to the same directory — harmless duplication.
    #
    # --force-rpath writes DT_RPATH instead of patchelf's default DT_RUNPATH.
    # The difference matters twice over:
    #   1. DT_RUNPATH is searched *after* LD_LIBRARY_PATH, so a stale host
    #      entry shadows the bundled libraries.  Measured: with DT_RUNPATH a
    #      decoy LD_LIBRARY_PATH shadows the bundled Qt ("file too short");
    #      with DT_RPATH the same binary ignores the decoy and runs.  This is
    #      what let us delete the launcher's LD_LIBRARY_PATH export.
    #   2. DT_RPATH is inherited by the whole dependency chain, DT_RUNPATH is
    #      not — a bundled library whose own dependency was pulled in
    #      indirectly still resolves.
    # We apply it to *every* ELF, not just the executables: dlopen'd Qt
    # plugins and module .so files are loaded with no executable of ours in
    # the picture, so each one has to carry its own search path, and each is
    # equally exposed to a hostile LD_LIBRARY_PATH.  The cost is that a user
    # can no longer LD_LIBRARY_PATH their way into overriding a bundled
    # library — which is precisely the point of a self-contained bundle.
    patchelf --force-rpath --set-rpath "\$ORIGIN:\$ORIGIN/$rel_to_lib" "$f" 2>/dev/null || \
      echo "  Warning: patchelf --force-rpath --set-rpath failed for $f"

    # Rewrite absolute /nix/store NEEDED entries to bare library names.
    # Nix can embed full store paths in DT_NEEDED (e.g. /nix/store/.../libfoo.so).
    # The dynamic linker resolves absolute NEEDED paths directly, bypassing
    # rpath entirely, so they must be converted to bare names.
    while IFS= read -r needed_entry; do
      if [[ "$needed_entry" == /nix/store/* ]]; then
        bare_name="$(basename "$needed_entry")"
        patchelf --replace-needed "$needed_entry" "$bare_name" "$f" 2>/dev/null || \
          echo "  Warning: patchelf --replace-needed failed for $needed_entry in $f"
      fi
    done < <(patchelf --print-needed "$f" 2>/dev/null)

    # Fix unversioned libvulkan.so NEEDED (Nix links against the unversioned
    # name, but non-dev Linux systems only ship libvulkan.so.1).
    if patchelf --print-needed "$f" 2>/dev/null | grep -qx 'libvulkan.so'; then
      patchelf --replace-needed libvulkan.so libvulkan.so.1 "$f" 2>/dev/null || \
        echo "  Warning: patchelf --replace-needed libvulkan.so failed for $f"
    fi

    interp="$(patchelf --print-interpreter "$f" 2>/dev/null)" || true
    if [[ -n "${interp:-}" && "$interp" == /nix/store/* ]]; then
      interp_name="$(basename "$interp")"
      if [ -f "$out/lib/$interp_name" ]; then
        patchelf --set-interpreter "$out/lib/$interp_name" "$f" 2>/dev/null || \
          echo "  Warning: patchelf --set-interpreter failed for $f"
      elif is_system_lib "$interp_name"; then
        # System interpreter — point it at the path this architecture's psABI
        # mandates.  That path is knowable at build time, so the ELF stays a
        # plain, directly-executable binary: the kernel records it (not a
        # loader) as the process image, /proc/self/exe is the truth, argv[0]
        # is whatever the caller passed, and a program that re-execs itself
        # gets itself.  An earlier design shipped every executable hidden
        # behind a shell launcher that ran it as `exec ld.so ./the-binary`;
        # that broke all three of those, and cost a real bug where a daemon
        # re-exec'd itself into the hidden ELF and died with ENOENT.
        if psabi_interp="$(psabi_interpreter "$f")"; then
          patchelf --set-interpreter "$psabi_interp" "$f" 2>/dev/null || \
            echo "  Warning: patchelf --set-interpreter failed for $f"
        else
          # Architecture we have no verified psABI path for.  Keep the old
          # best-effort guess rather than inventing one; it is at least no
          # worse than what shipped before.
          patchelf --set-interpreter "/lib/$interp_name" "$f" 2>/dev/null || \
            echo "  Warning: patchelf --set-interpreter failed for $f"
        fi
      fi
    fi
  done

fi

# ===========================================================================
# Phase 4 — Re-sign Mach-O binaries (macOS, must be after all patching)
# ===========================================================================
if [ "$IS_DARWIN" = "1" ]; then
  echo "Phase 4: Code signing..."
  find "$out" -type f | while IFS= read -r f; do
    filetype="$(file -b "$f" 2>/dev/null)" || continue
    [[ "$filetype" == *Mach-O* ]] || continue
    codesign -f -s - "$f" 2>/dev/null || \
      echo "  Warning: codesign failed for $f"
  done
fi

# ===========================================================================
# Phase 5 — Rewrite shebangs in bin/
# ===========================================================================
echo "Phase 5: Rewriting shebangs..."
for f in "$out"/bin/*; do
  [ -f "$f" ] || continue
  head_bytes="$(head -c 2 "$f" 2>/dev/null)" || continue
  if [[ "$head_bytes" == "#!" ]]; then
    first_line="$(head -n 1 "$f")"
    if [[ "$first_line" == \#\!/nix/store/* ]]; then
      interp_path="${first_line#\#\!}"
      interp_path="$(echo "$interp_path" | sed 's/^[[:space:]]*//')"
      interp_bin="$(basename "$(echo "$interp_path" | awk '{print $1}')")"
      interp_args="$(echo "$interp_path" | awk '{$1=""; print $0}' | sed 's/^[[:space:]]*//')"
      if [[ -n "$interp_args" ]]; then
        new_shebang="#!/usr/bin/env $interp_bin $interp_args"
      else
        new_shebang="#!/usr/bin/env $interp_bin"
      fi
      sed -i "1s|.*|$new_shebang|" "$f"
    fi
  fi
done

# ===========================================================================
# Phase 5b — Generate launchers for executables that need runtime environment
# ===========================================================================
# Phase 3 gives every ELF a psABI interpreter and a DT_RPATH, so the ordinary
# case needs no launcher at all: the binary in bin/ *is* the binary, it starts
# directly, and Qt finds bin/qt.conf because /proc/self/exe finally tells the
# truth.  (That is also why QT_PLUGIN_PATH and QML2_IMPORT_PATH are gone:
# qt.conf's relative Plugins/QmlImports paths only failed to resolve because
# the old launcher ran the program through ld.so, which made /proc/self/exe
# point at the loader.  Verified on a real Fedora Wayland desktop with both
# variables unset: the wayland platform plugin, its xdg-shell / decoration /
# EGL integrations, the xdgdesktopportal platform theme and QtQuick's
# qtquick2plugin all load from the bundle, and no host Qt library is mapped.
# LD_LIBRARY_PATH is gone for the DT_RPATH reason above.)
#
# What is left is the one thing no ELF header can express: libxkbcommon is
# compiled with DFLT_XKB_CONFIG_ROOT baked to a /nix/store path that does not
# exist on the target, and its lookup has no relative-to-the-binary fallback.
# Without XKB_CONFIG_ROOT, Qt Wayland's keymap dispatch dereferences a NULL
# xkb context and segfaults — proven by controlled experiment on a real
# Fedora Wayland session, same binary, unset -> SIGSEGV, set -> runs.  Note
# that containers cannot reproduce that failure (under Xvfb the keymap comes
# from the X server; headless weston has no seat, so no keymap is ever sent),
# so a green container run is not evidence that this launcher is unnecessary.
#
# So: emit a launcher only when xkb data was actually bundled, and only to
# export environment.  It never involves ld.so.
# The launcher is emitted when the bundle needs ANY environment variable set
# that the libraries cannot work out for themselves.  Today there are two, and
# they are independent:
#
#   XKB_CONFIG_ROOT        libxkbcommon has its config root baked to a
#                          /nix/store path that will not exist at runtime.
#   QT_QPA_PLATFORMTHEME   the xdg-desktop-portal theme has to be chosen by
#                          name; bundling the plugin is not enough.
#
# Gating both on xkb alone would mean a bundle that ships the portal plugin
# without libxkbcommon silently loses its host file dialogs, with nothing in
# the build log to say so.  So each contributes its own reason to emit.
_need_xkb=0
if [ "$xkb_detected" = "1" ] && [ -d "$out/share/X11/xkb" ]; then _need_xkb=1; fi
_need_theme=0
if [ -f "$qt_plugins_dir/platformthemes/libqxdgdesktopportal.so" ]; then _need_theme=1; fi

# GUI_APP is the caller's declaration (mkBundle's `guiApp`). Both variables
# above only matter once a Qt GUI platform plugin is loaded, and nothing the
# bundler can measure tells it whether that will happen — so a bundle that says
# it puts nothing on screen gets plain binaries and no companion ELF.
# The Windows test is explicit and comes first.  This gate was a two-arm chain
# in which Windows landed on the Unix side; it did not fire only because
# _need_xkb and _need_theme both happen to key on `.so` filenames a Windows
# staging tree never produces.  The launcher body is /bin/sh with `exec -a`,
# /proc/self/exe and colon-split $PATH — inapplicable to Windows in every
# respect, so nothing here should depend on that accident.
if [ "$IS_WINDOWS" != "1" ] && [ "$IS_DARWIN" != "1" ] && [ -d "$out/bin" ] && [ "${GUI_APP:-1}" = "1" ] \
     && { [ "$_need_xkb" = "1" ] || [ "$_need_theme" = "1" ]; }; then
  echo "Phase 5b: Generating environment launchers..."

  for f in "$out"/bin/*; do
    [ -f "$f" ] || continue
    filetype="$(file -b "$f" 2>/dev/null)" || continue
    [[ "$filetype" == *ELF* ]] || continue
    # Only executables get a launcher.  Presence of PT_INTERP is the reliable
    # discriminator: shared objects don't have one, and `file` reports PIE
    # executables as "shared object" on older versions, so its wording can't
    # be trusted here.
    [ -n "$(patchelf --print-interpreter "$f" 2>/dev/null || true)" ] || continue

    base="$(basename "$f")"
    real="$out/bin/.$base.elf"

    # Every executable in bin/ gets the launcher, not just the GUI ones.  We
    # cannot tell them apart reliably (an app's DT_NEEDED usually doesn't
    # mention libxkbcommon — the Qt platform plugin pulls it in at dlopen
    # time), guessing wrong means a segfault, and XKB_CONFIG_ROOT is inert
    # for a program that never opens a display.
    mv "$f" "$real"

    # The companion's own interpreter, so the launcher can say something
    # useful when a host does not have it (see the preflight below).
    launcher_interp="$(patchelf --print-interpreter "$real" 2>/dev/null || true)"

    cat > "$f" <<LAUNCHER_HEAD
#!/bin/sh
# Auto-generated launcher.  Sets the environment the bundled libraries cannot
# derive from their own location, then execs the real binary directly — never
# through ld.so, so /proc/self/exe and argv[0] stay honest.
BASE="$base"
INTERP="$launcher_interp"
LAUNCHER_HEAD

    cat >> "$f" <<'LAUNCHER_BODY'
# Resolve our own directory robustly.  When a parent (e.g. boost::process v2,
# Qt's QProcess, or an AppImage runtime that inherits the user's cwd) spawns
# us via PATH resolution or with a bare-name / relative argv[0], `$0` can be
# something that resolves against the caller's cwd — *not* our install dir.
# We anchor on a ground truth: our install dir is the one that contains the
# companion ELF ".$BASE.elf" next to us.  Try argv[0]-based resolution first,
# then fall back to a PATH walk looking for that companion — AppImage AppRun
# and similar wrappers always prepend our bin dir to PATH, so this fallback is
# reliable even when argv[0] is wrong.
_find_self_dir() {
  # Attempt 1: resolve via $1 ($0).
  _candidate=""
  case "$1" in
    /*)  _candidate="$1" ;;
    */*) _candidate="$PWD/$1" ;;
    *)
      _r="$(command -v "$1" 2>/dev/null || true)"
      case "$_r" in
        /*) _candidate="$_r" ;;
        *)  _candidate="$PWD/$1" ;;
      esac
      ;;
  esac
  if [ -n "$_candidate" ]; then
    _d="$(cd "$(dirname "$_candidate")" 2>/dev/null && pwd)" || _d=""
    if [ -n "$_d" ] && [ -f "$_d/.$BASE.elf" ]; then
      printf '%s\n' "$_d"
      return 0
    fi
  fi
  # Attempt 2: search PATH for a directory containing our companion ELF.
  _old_ifs="$IFS"
  IFS=:
  for _p in $PATH; do
    if [ -n "$_p" ] && [ -f "$_p/.$BASE.elf" ]; then
      IFS="$_old_ifs"
      # Canonicalise (PATH entries can be relative).
      _d="$(cd "$_p" 2>/dev/null && pwd)" && [ -n "$_d" ] && { printf '%s\n' "$_d"; return 0; }
    fi
  done
  IFS="$_old_ifs"
  # Last resort: best-effort fallback, whatever it resolves to.
  if [ -n "$_candidate" ]; then
    (cd "$(dirname "$_candidate")" 2>/dev/null && pwd) || printf '%s\n' "$PWD"
  else
    printf '%s\n' "$PWD"
  fi
}
SELF_DIR="$(_find_self_dir "$0")"

# xkeyboard-config data path — libxkbcommon was built with a hardcoded
# /nix/store path that won't exist at runtime; without this, Qt Wayland's
# keymap dispatch segfaults on a NULL xkb context.  This is one of the two
# reasons a launcher is emitted at all; the portal theme below is the other,
# and either alone is enough, so neither can assume the other applies.
if [ -d "$SELF_DIR/../share/X11/xkb" ]; then
  export XKB_CONFIG_ROOT="$SELF_DIR/../share/X11/xkb"
fi

# Route Qt file dialogs through xdg-desktop-portal so the host's own file
# chooser renders.  Unlike XKB_CONFIG_ROOT this isn't needed for correctness —
# Qt finds the plugin via qt.conf on its own — but the theme has to be *chosen*
# by name, and nothing in the bundle can do that for us.  Only set it when the
# plugin is actually bundled and the user hasn't picked a theme themselves.
if [ -f "$SELF_DIR/../lib/qt/plugins/platformthemes/libqxdgdesktopportal.so" ] \
     && [ -z "${QT_QPA_PLATFORMTHEME:-}" ]; then
  export QT_QPA_PLATFORMTHEME="xdgdesktopportal"
fi

REAL="$SELF_DIR/.$BASE.elf"

# The old launcher probed for the loader and said so when it found none.  exec
# below would instead fail with ENOENT naming $REAL — the kernel reporting the
# missing *interpreter*, not the missing file — which is precisely the
# unreadable symptom this change exists to stop producing.  One stat is cheap.
if [ -n "$INTERP" ] && [ ! -e "$INTERP" ]; then
  echo "$BASE: this bundle needs the system dynamic linker at $INTERP, which" >&2
  echo "  does not exist on this host.  That path is mandated by the platform" >&2
  echo "  ABI, so a glibc system should have it; musl systems (Alpine) cannot" >&2
  echo "  run these binaries at all." >&2
  exit 1
fi

# Exec the real ELF directly.  Its PT_INTERP is the psABI loader path, which
# exists on every glibc host, so there is nothing to probe and no reason to
# hand the program to ld.so.  The kernel therefore records $REAL as the
# process image: /proc/self/exe resolves to it (Qt's applicationDirPath and
# hence qt.conf work), and `exec -a` passes on our own $0 rather than the
# companion's dotted name.  For a #! script the kernel rewrites argv[0] to the
# script path it resolved, so that $0 is always a real, runnable path to this
# launcher — a program that re-execs itself from argv[0] lands back here and
# keeps its environment instead of starting the bare ELF.
#
# Note what this does NOT cover: /proc/self/exe is $REAL, not this script, so a
# program that re-execs from /proc/self/exe restarts the bare ELF and loses the
# environment set above.  Such a caller has to map `.<name>.elf` back to
# `<name>` itself (logos-logoscore-cli's paths.cpp does exactly that).  Both
# identities are honest here — they simply answer different questions — but
# only argv[0] round-trips through the launcher.
#
# `exec -a` is a bashism, and /bin/sh is dash on Debian/Ubuntu and busybox ash
# on a few others — both reject it.  We keep the /bin/sh shebang (the only
# interpreter guaranteed to exist) and pick the argv[0]-preserving path at
# runtime instead:
#   1. our own shell, if it happens to support -a (bash, ksh, zsh as sh);
#   2. otherwise bash, which is not guaranteed but is present on every glibc
#      desktop distro.  `bash -c 'script' name args...` sets $0 to name, so
#      the inner exec sees our argv[0] as $0 and $REAL "$@" as "$@";
#   3. otherwise a plain exec, which still runs the right program — only
#      argv[0] is then the companion's dotted path.
if (exec -a _probe true) 2>/dev/null; then
  exec -a "$0" "$REAL" "$@"
elif command -v bash >/dev/null 2>&1; then
  exec bash -c 'exec -a "$0" "$@"' "$0" "$REAL" "$@"
fi
exec "$REAL" "$@"
LAUNCHER_BODY

    chmod +x "$f"
    # Name what this launcher is actually for: with independent gates it can
    # be either variable, or both.
    _why=""
    [ "$_need_xkb" = "1" ]   && _why="XKB_CONFIG_ROOT"
    [ "$_need_theme" = "1" ] && _why="${_why:+$_why, }QT_QPA_PLATFORMTHEME"
    echo "  $base -> .$base.elf (launcher: $_why)"
  done
fi

# ===========================================================================
# Phase 6 — Verify portability (check for non-portable references)
# ===========================================================================
echo "Phase 6: Verifying portability..."

# ---------------------------------------------------------------------------
# Windows / PE contract checks
# ---------------------------------------------------------------------------
# The generic checks below are otool/patchelf-only, so before this arm existed
# Phase 6 was a complete no-op on a PE bundle and printed "All references are
# portable." over an unusable tree.  There are no rpaths or interpreters to
# check on a PE — what can go wrong is a base name that resolves to nothing at
# load time, and the shape of the bundle around it.  Every check prints the
# number it counted, because the failure mode this whole branch exists to
# prevent is a check that passes by measuring nothing.
if [ "$IS_WINDOWS" = "1" ]; then
  win_errors=0

  # -- known-positive control for the import reader -------------------------
  # The real control ran in Phase 2, BEFORE the first sweep, because every
  # staging decision depends on it — see pe_reader_control.  Restating it here
  # would only re-prove what the sweep already relied on.  What this line does
  # is name the reader in the log, so a green Phase 6 can be traced to the
  # binary that produced it.
  echo "  Import-table reader: $pe_objdump (proved non-empty in Phase 2)"

  # -- bundle contract ------------------------------------------------------
  if [ "$qt_detected" = "1" ] && [ "$qt_is_host" != "1" ]; then
    if [ ! -f "$out/bin/qt.conf" ]; then
      echo "  ERROR: bin/qt.conf is missing; Qt would search an empty plugin path" >&2
      win_errors=$((win_errors + 1))
    fi
    win_plugin_dlls="$(find "$qt_plugins_dir" -type f -name '*.dll' 2>/dev/null | wc -l)"
    echo "  Staged Qt plugin DLLs: $win_plugin_dlls"
    if [ "$win_plugin_dlls" -eq 0 ]; then
      echo "  ERROR: no Qt plugin DLLs were staged under ${qt_plugins_dir#"$out"/}" >&2
      win_errors=$((win_errors + 1))
    fi
    if [ "${GUI_APP:-1}" = "1" ] && [ ! -f "$qt_plugins_dir/platforms/qwindows.dll" ]; then
      echo "  ERROR: ${qt_plugins_dir#"$out"/}/platforms/qwindows.dll is missing;" \
           "a GUI app cannot create a window without the QPA plugin" >&2
      win_errors=$((win_errors + 1))
    fi
    # Presence-only, non-fatal.  These directories are reached by LoadLibrary
    # with a name Qt computes at runtime, so no import table mentions them and
    # static analysis cannot prove they are needed — nor that they are not.
    # Saying which are absent is the most this check can honestly do.
    for _d in styles imageformats tls iconengines; do
      if [ ! -d "$qt_plugins_dir/$_d" ]; then
        echo "  Note: no $_d/ plugin directory was staged.  Qt loads these by" \
             "computed name; if the app asks for one it will fail at runtime" \
             "and nothing here can predict that."
      fi
    done
  fi

  # BOTH directions.  v1 asserted only "QML staged => Qt6Quick.dll", which is
  # why nothing caught the converse: Qt6Quick.dll in bin/ with an empty QML
  # tree, and a qt.conf naming a Qml2Imports directory that does not exist.
  win_qml_entries=0
  [ -d "$qt_qml_dir" ] && win_qml_entries="$(find "$qt_qml_dir" -mindepth 1 2>/dev/null | wc -l)"
  echo "  QML import tree: $win_qml_entries entr(y/ies) under ${qt_qml_dir#"$out"/}"
  # The forward assertion now asks the GATE, not one hard-coded DLL name.
  # `[ ! -f "$out/bin/Qt6Quick.dll" ]` did not match win_qml_gate, which fires
  # on Qt6Qml*.dll as well — so a QtQml-without-QtQuick bundle that legitimately
  # staged QML modules was a hard build failure, while the shape this check was
  # meant to catch (QML staged, tree empty) went to the check below instead and
  # only by accident.
  #
  # As written it restates the gate's own invariant where the tree is visible,
  # so on the current flow it cannot fire: qt_qml_found=1 implies the gate was
  # true when stage_qml_modules ran, and nothing removes a DLL from bin/
  # afterwards.  It is kept as the cheap half of the pair, against a future
  # reordering of the two.
  if [ "${qt_qml_found:-0}" = "1" ] && ! win_qml_gate; then
    echo "  ERROR: QML modules were staged but bin/ holds no Qt6Qml*/Qt6Quick*" \
         "DLL to load them" >&2
    win_errors=$((win_errors + 1))
  fi
  # This is the half that does the work, and it did not exist: "QML staging ran
  # and produced NOTHING".  Previously an empty QML tree was caught only when
  # bin/Qt6Quick.dll happened to be present, i.e. the right outcome for the
  # wrong reason, and a Qt6Qml-only bundle with an empty tree passed.
  if [ "${qt_qml_found:-0}" = "1" ] && [ "$win_qml_entries" -eq 0 ]; then
    echo "  ERROR: QML modules were reported staged but ${qt_qml_dir#"$out"/} is" \
         "empty or absent; every QML import in this app would fail to resolve" >&2
    win_errors=$((win_errors + 1))
  fi
  # Kept narrow on purpose: QtQuick genuinely cannot run without its QML
  # modules, whereas Qt6Qml alone is linked by pure-C++ QJSEngine users that
  # need no import directory at all.  Widening this one to the gate would
  # reject that valid shape.
  if [ -f "$out/bin/Qt6Quick.dll" ] && [ "$win_qml_entries" -eq 0 ]; then
    echo "  ERROR: bin/Qt6Quick.dll is in this bundle but the QML import tree" \
         "${qt_qml_dir#"$out"/} is empty or absent; QtQuick cannot load a single" \
         "type without it" >&2
    win_errors=$((win_errors + 1))
  fi

  # -- nothing was lost, and nothing dangles --------------------------------
  # By SET, not by count.  The count comparison this replaces ran after the
  # sweep had already added ~60 files to bin/ (19 -> 80 on the real bundle), so
  # a Phase 1 loss of up to 60 source entries would still have passed it.  The
  # tight count check does still exist — in Phase 1c, before the sweep, where
  # the arithmetic is still meaningful.
  win_src_bin=0
  win_lost_names=0
  if [ -d "$DRV_PATH/bin" ]; then
    while IFS= read -r n; do
      win_src_bin=$((win_src_bin + 1))
      [ -e "$out/bin/$n" ] && continue
      echo "  ERROR: bin/$n is in the source derivation but not in the bundle" >&2
      win_lost_names=$((win_lost_names + 1))
    done < <(find "$DRV_PATH/bin" -maxdepth 1 -mindepth 1 -printf '%f\n' | sort)
  fi
  # `[ -d ]` guard: a Windows output need not have a bin/ at all. A Logos module
  # is `lib/<name>_plugin.dll` and nothing else, and nix-bundle-lgx feeds exactly
  # those derivations through here -- so this is a shape the workspace produces,
  # not a hypothetical. Unguarded it emitted a bare
  # `find: '.../bin': No such file or directory` with no ERROR line and no
  # phase name, on a branch whose stated standard is to fail loudly.
  win_out_bin=0
  [ -d "$out/bin" ] && win_out_bin="$(find "$out/bin" -maxdepth 1 -mindepth 1 | wc -l)"
  echo "  bin/ entries: $win_src_bin in the source derivation, all present by" \
       "name in the bundle's $win_out_bin ($win_lost_names missing)"
  if [ "$win_lost_names" -gt 0 ]; then
    win_errors=$((win_errors + win_lost_names))
  fi
  win_dangling="$(find "$out" -xtype l 2>/dev/null | wc -l)"
  if [ "$win_dangling" -gt 0 ]; then
    echo "  ERROR: $win_dangling dangling symlink(s) in the bundle" \
         "(a dangling link is not -type f, so every other check silently skips it)" >&2
    find "$out" -xtype l -printf '    %P -> %l\n' 2>/dev/null || true
    win_errors=$((win_errors + 1))
  fi

  # -- the fixpoint actually converged --------------------------------------
  # Re-derived from scratch, on BOTH sides.  The import side always was; the
  # RESOLUTION side was not, and the comment used to claim otherwise:
  # pe_dir_index is memoised behind pe_dir_scanned, and the sweep both scanned
  # $out/bin and then wrote its own staging decisions straight into that map —
  # so Phase 6 was asking the sweep whether the sweep's writes had landed.  That
  # is exactly why a mirrored non-PE survived verification: the map was updated
  # at staging time and nobody looked at the disk again.
  #
  # Dropping both memo tables costs one readdir per directory and one `file` per
  # entry that is not already classified, and makes every answer below come from
  # the tree as it now stands.
  unset pe_dir_have pe_dir_scanned
  declare -A pe_dir_have
  declare -A pe_dir_scanned
  echo "  Verifying every PE import resolves inside the bundle..."
  echo "  (directory maps re-listed from disk; the sweep's bookkeeping is discarded)"
  win_pe_files=0
  win_import_names=0
  win_arch_checked=0
  win_archs=""
  # Only mention bin/ in the unresolved-import error when there IS one; a
  # module-only output has none, and naming a directory that does not exist
  # sends the reader looking for a staging bug that is not there.
  pe_resolve_app_dir
  app_present=""
  [ -n "$pe_app_dir" ] && app_present=1
  # Same enumeration the sweep used — pe_files — so the fixer and the checker
  # cannot disagree about what a root is.  That asymmetry was a build failure
  # on valid input, twice.
  while IFS= read -r f; do
    win_pe_files=$((win_pe_files + 1))
    fdir="$(dirname "$f")"
    pe_dir_index "$fdir"
    pe_dir_index "$out/bin"
    f_arch="$(pe_arch_or_die "$f" "a PE in this bundle")"
    case " $win_archs " in *" $f_arch "*) ;; *) win_archs="$win_archs $f_arch" ;; esac
    while IFS= read -r imp; do
      [ -n "$imp" ] || continue
      win_import_names=$((win_import_names + 1))
      is_windows_system_dll "$imp" && continue
      key="${imp,,}"
      # Which FILE satisfies it, not merely whether something does: the
      # architecture check below needs the provider, and asking for it is what
      # keeps "resolved" meaning "a loadable module of the right machine is
      # there" rather than "a name matched".
      hit=""
      if [ -n "${pe_dir_have["$fdir|$key"]:-}" ]; then
        hit="$fdir/${pe_dir_have["$fdir|$key"]}"
      elif [ -n "$pe_app_dir" ] && [ -n "${pe_dir_have["$pe_app_dir|$key"]:-}" ]; then
        hit="$pe_app_dir/${pe_dir_have["$pe_app_dir|$key"]}"
      fi
      if [ -z "$hit" ]; then
        echo "  ERROR: ${f#"$out"/} imports $imp, which is in neither its own" \
             "directory nor${app_present:+ bin/ nor} the closure" >&2
        win_errors=$((win_errors + 1))
        continue
      fi
      hit_arch="$(pe_arch_or_die "$hit" "the $imp satisfying ${f#"$out"/}")"
      if [ "$f_arch" != "$hit_arch" ]; then
        echo "  ERROR: ${f#"$out"/} is $f_arch but the $imp that satisfies it" \
             "(${hit#"$out"/}) is $hit_arch; Windows rejects that with" \
             "ERROR_BAD_EXE_FORMAT at load time" >&2
        win_errors=$((win_errors + 1))
      else
        win_arch_checked=$((win_arch_checked + 1))
      fi
    done < <(pe_imports "$f")
  done < <(pe_files)
  echo "  Checked $win_pe_files PE file(s), $win_import_names import name(s)"
  echo "  Machine check: $win_arch_checked resolved import(s) matched their" \
       "importer's architecture; architectures present in this bundle:${win_archs:- none}"
  # ...and now COMPARE it, rather than printing a number nobody reads.
  # `win_arch_checked` on its own cannot carry the signal: a bundle whose every
  # non-system import is satisfied out of bin/ by a same-machine provider counts
  # them, but so does a bundle with no non-system imports at all — both print 0
  # legitimately, so there is no baseline a degraded 0 could look wrong against.
  # The architecture SET is the number with a defensible expectation: everything
  # here comes out of one cross target, so a bundle carrying two machines means
  # a wrong-target input reached the closure.  Windows would only say so at load
  # time, before main(), with no output.
  #
  # A policy choice, not a law — a bundle deliberately shipping a 32-bit helper
  # beside a 64-bit app is a legitimate thing that this rejects.  No such bundle
  # exists in this workspace; when one does, this is the line to revisit.
  win_arch_count="$(printf '%s\n' $win_archs | grep -c . || true)"
  if [ "${win_arch_count:-0}" -gt 1 ]; then
    echo "  ERROR: this bundle carries PEs for more than one machine:$win_archs" >&2
    echo "  Everything in a cross bundle comes from a single target, so a second" >&2
    echo "  architecture means an input built for the wrong one reached the" >&2
    echo "  closure.  Windows reports that as ERROR_BAD_EXE_FORMAT at load time," >&2
    echo "  before main() runs and with nothing printed." >&2
    win_errors=$((win_errors + 1))
  fi
  pe_report_zero_import_files
  # And re-adjudicate the reader itself over this whole pass: this loop just
  # re-read every import table in the bundle, so anything it could not read is
  # a file whose "resolves" verdict above was produced from an empty list.
  pe_assert_reader_read_everything "Phase 6"
  # win_pe_files == 0 is already impossible: Phase 1c hard-errors when Nix says
  # Windows and the tree holds no PE.  win_import_names == 0 across a non-empty
  # set of PEs would mean the reader went blind between Phase 2 and here.
  if [ "$win_pe_files" -eq 0 ] || [ "$win_import_names" -eq 0 ]; then
    echo "  ERROR: found no PE files or no import names to check — this pass" \
         "measured nothing, so its clean result means nothing" >&2
    exit 1
  fi

  if [ "$win_errors" -gt 0 ]; then
    echo "FAILED: $win_errors Windows bundle contract violation(s)"
    exit 1
  fi
  # Deliberately NOT "Windows bundle contract satisfied", which reads as
  # "starts on Windows" and is not what was checked.  Nothing in this build ran
  # on Windows; what it proved is a property of import TABLES.  A DLL reached
  # by LoadLibrary with a name computed at runtime — a Qt style plugin selected
  # by name, d3dcompiler, ANGLE — appears in no import table, so it is covered
  # only by the presence checks above, and a bundle can still exit 0xC0000135
  # before main() despite everything here being green.
  echo "  PE import tables: every one of the $win_import_names import name(s)" \
       "across $win_pe_files PE file(s) resolves inside the bundle or to a" \
       "Windows system DLL."
  echo "  NOT checked (uncheckable statically): DLLs loaded by a name computed" \
       "at runtime.  Those are covered only by the directory presence checks" \
       "above."
fi

test_dir="$(mktemp -d)"
[ -d "$out/bin" ] && cp -a "$out/bin" "$test_dir/bin"
[ -d "$out/lib" ] && cp -a "$out/lib" "$test_dir/lib"
for dir in "${extra_dirs[@]+"${extra_dirs[@]}"}"; do
  [ -d "$out/$dir" ] && cp -a "$out/$dir" "$test_dir/$dir"
done

errors=0

check_macho() {
  local f="$1"
  local rel="${f#$test_dir/}"

  # Check load commands (otool -L)
  otool -L "$f" 2>/dev/null | tail -n +2 | while IFS= read -r line; do
    # Skip fat binary architecture headers (e.g. "/path/to/lib (architecture arm64):")
    [[ "$line" == *"(architecture"* ]] && continue
    dep="$(echo "$line" | sed -E 's/^[[:space:]]*([^[:space:]]+).*/\1/')"
    if ! is_portable_ref "$dep"; then
      echo "  ERROR: $rel has non-portable load command: $dep"
      echo "1" >> "$test_dir/.errors"
    fi
  done

  # Check install name (otool -D)
  local install_id
  install_id="$(otool -D "$f" 2>/dev/null | tail -n +2 | head -1 | xargs)" || true
  if [[ -n "$install_id" ]] && ! is_portable_ref "$install_id"; then
    echo "  ERROR: $rel has non-portable install name: $install_id"
    echo "1" >> "$test_dir/.errors"
  fi

  # Check rpaths (otool -l)
  otool -l "$f" 2>/dev/null | awk '/cmd LC_RPATH/{found=1} found && /path /{print $2; found=0}' | while IFS= read -r rpath; do
    if ! is_portable_ref "$rpath"; then
      echo "  ERROR: $rel has non-portable rpath: $rpath"
      echo "1" >> "$test_dir/.errors"
    fi
  done
}

check_elf() {
  local f="$1"
  local rel="${f#$test_dir/}"

  # Check RPATH/RUNPATH
  local rpath_val
  rpath_val="$(patchelf --print-rpath "$f" 2>/dev/null)" || true
  if [ -n "$rpath_val" ]; then
    local IFS=':'
    local -a rpath_entries
    read -ra rpath_entries <<< "$rpath_val"
    unset IFS
    for entry in "${rpath_entries[@]}"; do
      case "$entry" in
        '$ORIGIN'|'${ORIGIN}') ;; # portable (same directory as the binary)
        '$ORIGIN'/*|'${ORIGIN}'/*) ;; # portable (relative to binary directory)
        /lib/*|/lib64/*|/usr/lib/*|/usr/lib64/*) ;; # system paths
        '') ;; # empty
        *)
          echo "  ERROR: $rel has non-portable rpath entry: $entry"
          echo "1" >> "$test_dir/.errors"
          ;;
      esac
    done
  fi

  # Check interpreter
  local interp
  interp="$(patchelf --print-interpreter "$f" 2>/dev/null)" || true
  if [[ -n "$interp" && "$interp" == /nix/store/* ]]; then
    echo "  ERROR: $rel has non-portable interpreter: $interp"
    echo "1" >> "$test_dir/.errors"
  fi

  # Check NEEDED entries for absolute /nix/store paths
  local needed
  needed="$(patchelf --print-needed "$f" 2>/dev/null)" || true
  for lib_name in $needed; do
    if [[ "$lib_name" == /nix/store/* ]]; then
      echo "  ERROR: $rel has non-portable NEEDED entry: $lib_name"
      echo "1" >> "$test_dir/.errors"
    fi
  done
}

find "$test_dir" -type f | while IFS= read -r f; do
  filetype="$(file -b "$f" 2>/dev/null)" || continue
  if [[ "$filetype" == *Mach-O* ]]; then
    check_macho "$f"
  elif [[ "$filetype" == *ELF* ]]; then
    check_elf "$f"
  fi
done

# Check for /nix/ paths embedded in binary data.
# PE is included ON WINDOWS: this check is the one part of Phase 6 that is
# genuinely format-agnostic — it is a string scan — and skipping PEs made a
# Windows bundle pass it vacuously.
#
# The IS_WINDOWS guard is load-bearing, not decoration.  Unguarded, this arm
# changes Linux and macOS behaviour: a non-Windows bundle that merely CARRIES a
# PE as data gets string-scanned, and under `warnOnBinaryData = false` — which
# is what `bundlers.default` passes — a single /nix/ string inside it becomes a
# hard build failure. Demonstrated on x86_64-linux: bin/run.sh + a real PE32+
# with one appended /nix/ line exits 0 on the base bundler and 1 with the arm
# unguarded.
echo "  Checking for embedded /nix/ paths..."
find "$test_dir" -type f | while IFS= read -r f; do
  filetype="$(file -b "$f" 2>/dev/null)" || continue
  case "$filetype" in
    *Mach-O*|*ELF*) ;;
    *PE32*)         [ "$IS_WINDOWS" = "1" ] || continue ;;
    *)              continue ;;
  esac
  rel="${f#$test_dir/}"
  nix_refs="$(strings "$f" 2>/dev/null | grep -c '/nix/' || true)"
  if [ "$nix_refs" -gt 0 ]; then
    # On a PE these are never fatal, whatever warnOnBinaryData says.
    #
    # The scan exists to answer "will this run outside /nix?". For ELF and
    # Mach-O an embedded store path can BE the answer — it is how the loader
    # finds libraries. A PE has no rpath and no interpreter: its imports are
    # base names resolved against the search path, so a /nix/ string in one is
    # inert residue (gcc include paths in debug metadata, OPENSSLDIR, the
    # occasional __FILE__), never a load-time reference.
    #
    # Treating them as errors made the DEFAULT configuration unbuildable on
    # Windows, and nothing caught it because every Windows run so far happened
    # to pass warnOnBinaryData = true. mkBundle's own default is false, and
    # `bundlers.default` passes false. Demonstrated on a fixture pair identical
    # but for the flag: 10 "non-portable" hits in stock mingw Qt and OpenSSL —
    # Qt6Core.dll alone carries 28 x86_64-w64-mingw32-gcc-15.2.0 include paths.
    if [ "$IS_WINDOWS" = "1" ]; then
      echo "  NOTE: $rel contains $nix_refs embedded /nix/ string(s) (inert on PE: no rpath, imports are base names)"
    elif [ "${WARN_ON_BINARY_DATA:-0}" = "1" ]; then
      echo "  WARNING: $rel contains $nix_refs embedded /nix/ reference(s) in binary data"
    else
      echo "  ERROR: $rel contains $nix_refs embedded /nix/ reference(s) in binary data"
      echo "1" >> "$test_dir/.errors"
    fi
    # The listing is a diagnostic for a real portability problem; on PE the
    # note above already says the strings are inert, so do not dump dozens of
    # gcc include paths per DLL on every Windows build.
    if [ "$IS_WINDOWS" != "1" ]; then
      strings "$f" 2>/dev/null | grep '/nix/' | sort -u | while IFS= read -r ref; do
        echo "    $ref"
      done
    fi
  fi
done

if [ -f "$test_dir/.errors" ]; then
  error_count="$(wc -l < "$test_dir/.errors")"
  rm -rf "$test_dir"
  echo "FAILED: Found $error_count non-portable reference(s)"
  exit 1
fi

rm -rf "$test_dir"
echo "  All references are portable."

echo "Done!"
