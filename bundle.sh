#!/bin/bash
set -euo pipefail

mkdir -p "$out"

# Build exclude patterns array
exclude_patterns=()
if [ -n "${EXCLUDE_LIBS:-}" ]; then
  while IFS= read -r pat; do
    [ -n "$pat" ] && exclude_patterns+=("$pat")
  done <<< "$EXCLUDE_LIBS"
fi

is_excluded() {
  local lib_name="$1"
  for pat in "${exclude_patterns[@]+"${exclude_patterns[@]}"}"; do
    # Use bash glob matching
    # shellcheck disable=SC2254
    case "$lib_name" in
      $pat) return 0 ;;
    esac
  done
  return 1
}

# ===========================================================================
# Phase 1 — Copy executables and libraries from the main derivation
# ===========================================================================
echo "Phase 1: Copying executables and libraries..."
if [ -d "$DRV_PATH/bin" ]; then
  mkdir -p "$out/bin"
  for f in "$DRV_PATH"/bin/*; do
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

# ===========================================================================
# Phase 2 — Trace and collect shared library dependencies
# ===========================================================================
echo "Phase 2: Tracing shared library dependencies..."

declare -A visited

collect_lib() {
  local lib_path="$1"
  local lib_name
  lib_name="$(basename "$lib_path")"

  [[ -z "${visited[$lib_path]:-}" ]] || return 0
  visited[$lib_path]=1

  if is_excluded "$lib_name"; then
    echo "  Skipping (excluded): $lib_name"
    return 0
  fi

  local real_path
  real_path="$(realpath "$lib_path" 2>/dev/null)" || return 0
  [ -f "$real_path" ] || return 0

  if [ ! -e "$out/lib/$lib_name" ]; then
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

    otool -L "$bin" 2>/dev/null | tail -n +2 | while IFS= read -r line; do
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
    done
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

# Fix absolute symlinks in lib/ that point into /nix/store
if [ -d "$out/lib" ]; then
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

if [ "$IS_DARWIN" = "1" ]; then

  rewrite_macho() {
    local f="$1"
    local f_dir
    f_dir="$(dirname "$f")"
    local rel_to_lib
    rel_to_lib="$(loader_path_to_lib "$f_dir")"
    local lib_prefix="@loader_path/$rel_to_lib"

    otool -L "$f" 2>/dev/null | tail -n +2 | while IFS= read -r line; do
      dep="$(echo "$line" | sed -E 's/^[[:space:]]*([^[:space:]]+).*/\1/')"
      [[ "$dep" == /nix/store/* ]] || continue
      lib_name="$(basename "$dep")"
      if [ -f "$out/lib/$lib_name" ] || [ -L "$out/lib/$lib_name" ]; then
        install_name_tool -change "$dep" "$lib_prefix/$lib_name" "$f" 2>/dev/null || \
          echo "  Warning: install_name_tool -change failed for $dep in $f"
      elif is_excluded "$lib_name"; then
        # Excluded system library — rewrite to /usr/lib/ (strip minor version)
        local sys_path
        sys_path="$(macos_system_lib_path "$lib_name")"
        install_name_tool -change "$dep" "$sys_path" "$f" 2>/dev/null || \
          echo "  Warning: install_name_tool -change failed for $dep in $f"
      fi
    done

    local current_id
    current_id="$(otool -D "$f" 2>/dev/null | tail -n +2 | head -1 | xargs)" || true
    if [[ -n "$current_id" && "$current_id" == /nix/store/* ]]; then
      local id_name
      id_name="$(basename "$current_id")"
      if is_excluded "$id_name"; then
        local sys_id_path
        sys_id_path="$(macos_system_lib_path "$id_name")"
        install_name_tool -id "$sys_id_path" "$f" 2>/dev/null || \
          echo "  Warning: install_name_tool -id failed for $f"
      else
        install_name_tool -id "$lib_prefix/$id_name" "$f" 2>/dev/null || \
          echo "  Warning: install_name_tool -id failed for $f"
      fi
    fi

    # Delete all existing rpaths (they point to build dirs or /nix/store)
    otool -l "$f" 2>/dev/null | awk '/cmd LC_RPATH/{found=1} found && /path /{print $2; found=0}' | while IFS= read -r rpath; do
      install_name_tool -delete_rpath "$rpath" "$f" 2>/dev/null || true
    done

    # Add rpath pointing to our lib/ relative to this binary
    install_name_tool -add_rpath "$lib_prefix" "$f" 2>/dev/null || true
  }

  find "$out" -type f | while IFS= read -r f; do
    filetype="$(file -b "$f" 2>/dev/null)" || continue
    [[ "$filetype" == *Mach-O* ]] || continue
    echo "  ${f#$out/}"
    rewrite_macho "$f"
  done

else

  find "$out" -type f | while IFS= read -r f; do
    filetype="$(file -b "$f" 2>/dev/null)" || continue
    [[ "$filetype" == *ELF* ]] || continue
    echo "  ${f#$out/}"

    f_dir="$(dirname "$f")"
    rel_to_lib="$(loader_path_to_lib "$f_dir")"

    patchelf --set-rpath "\$ORIGIN/$rel_to_lib" "$f" 2>/dev/null || \
      echo "  Warning: patchelf --set-rpath failed for $f"

    interp="$(patchelf --print-interpreter "$f" 2>/dev/null)" || true
    if [[ -n "${interp:-}" && "$interp" == /nix/store/* ]]; then
      interp_name="$(basename "$interp")"
      if [ -f "$out/lib/$interp_name" ]; then
        patchelf --set-interpreter "$out/lib/$interp_name" "$f" 2>/dev/null || \
          echo "  Warning: patchelf --set-interpreter failed for $f"
      elif is_excluded "$interp_name"; then
        # Excluded system interpreter — rewrite to standard path
        sys_interp="/lib/$interp_name"
        [ -f "/lib64/$interp_name" ] && sys_interp="/lib64/$interp_name"
        patchelf --set-interpreter "$sys_interp" "$f" 2>/dev/null || \
          echo "  Warning: patchelf --set-interpreter failed for $f"
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
# Phase 6 — Verify portability (check for non-portable references)
# ===========================================================================
echo "Phase 6: Verifying portability..."

test_dir="$(mktemp -d)"
[ -d "$out/bin" ] && cp -a "$out/bin" "$test_dir/bin"
[ -d "$out/lib" ] && cp -a "$out/lib" "$test_dir/lib"

errors=0

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

check_macho() {
  local f="$1"
  local rel="${f#$test_dir/}"

  # Check load commands (otool -L)
  otool -L "$f" 2>/dev/null | tail -n +2 | while IFS= read -r line; do
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
        '$ORIGIN'/*|'${ORIGIN}'/*) ;; # portable
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

  # Check NEEDED libs resolve (using the copied tree)
  local needed
  needed="$(patchelf --print-needed "$f" 2>/dev/null)" || true
  # We don't fail on NEEDED since they're bare names resolved via rpath
}

find "$test_dir" -type f | while IFS= read -r f; do
  filetype="$(file -b "$f" 2>/dev/null)" || continue
  if [[ "$filetype" == *Mach-O* ]]; then
    check_macho "$f"
  elif [[ "$filetype" == *ELF* ]]; then
    check_elf "$f"
  fi
done

# Check for /nix/ paths embedded in binary data
echo "  Checking for embedded /nix/ paths..."
find "$test_dir" -type f | while IFS= read -r f; do
  filetype="$(file -b "$f" 2>/dev/null)" || continue
  [[ "$filetype" == *Mach-O* || "$filetype" == *ELF* ]] || continue
  rel="${f#$test_dir/}"
  nix_refs="$(strings "$f" 2>/dev/null | grep -c '/nix/' || true)"
  if [ "$nix_refs" -gt 0 ]; then
    if [ "${WARN_ON_BINARY_DATA:-0}" = "1" ]; then
      echo "  WARNING: $rel contains $nix_refs embedded /nix/ reference(s) in binary data"
    else
      echo "  ERROR: $rel contains $nix_refs embedded /nix/ reference(s) in binary data"
      echo "1" >> "$test_dir/.errors"
    fi
    strings "$f" 2>/dev/null | grep '/nix/' | sort -u | while IFS= read -r ref; do
      echo "    $ref"
    done
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
