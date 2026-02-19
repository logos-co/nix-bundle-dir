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

# Trace deps of shared libraries in extra directories
for dir in "${extra_dirs[@]+"${extra_dirs[@]}"}"; do
  if [ -d "$out/$dir" ]; then
    while IFS= read -r f; do
      trace_deps "$f"
    done < <(find "$out/$dir" -type f \( -name '*.dylib' -o -name '*.so' \))
  fi
done

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
# Phase 2b — Bundle Qt plugins (if Qt is present)
# ===========================================================================
# Qt plugins are loaded at runtime via dlopen and won't appear in the
# dependency trace. If we bundled any Qt library, search the closure for
# the plugins directory, copy it, trace plugin deps, and create qt.conf.
qt_detected=0
qt_is_host=0
if [ "$framework_count" -gt 0 ]; then
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
      break
    fi
  done
fi

if [ "$qt_detected" = "1" ] && [ "$qt_is_host" = "1" ]; then
  echo "Phase 2b: Skipping Qt plugin/QML bundling (Qt is host-provided)"
elif [ "$qt_detected" = "1" ]; then
  echo "Phase 2b: Bundling Qt plugins..."
  qt_plugins_found=0

  while IFS= read -r storePath; do
    # Look for Qt plugin directories (qt-5/plugins, qt-6/plugins, or just plugins/platforms)
    for candidate in "$storePath/lib/qt-6/plugins" "$storePath/lib/qt-5/plugins" "$storePath/share/qt-6/plugins" "$storePath/share/qt-5/plugins" "$storePath/lib/qt6/plugins" "$storePath/lib/qt5/plugins"; do
      if [ -d "$candidate/platforms" ]; then
        echo "  Found Qt plugins: $candidate"
        mkdir -p "$out/lib/qt/plugins"
        cp -aL "$candidate"/* "$out/lib/qt/plugins/"
        chmod -R u+w "$out/lib/qt/plugins" 2>/dev/null || true
        qt_plugins_found=1
        break
      fi
    done
    [ "$qt_plugins_found" = "1" ] && break
  done < "$CLOSURE_PATHS"

  if [ "$qt_plugins_found" = "1" ]; then
    # Remove build artifacts from plugins (static libs, build metadata)
    find "$out/lib/qt/plugins" \( -name '*.a' -o -name '*.prl' -o -name '*.o' \) -delete 2>/dev/null || true
    while IFS= read -r junk_dir; do
      rm -rf "$junk_dir"
    done < <(find "$out/lib/qt/plugins" -type d -name 'objects-Release' 2>/dev/null)
    find "$out/lib/qt/plugins" -type d -empty -delete 2>/dev/null || true

    # Trace deps of all plugin shared libraries
    echo "  Tracing plugin dependencies..."
    while IFS= read -r plugin; do
      trace_deps "$plugin"
    done < <(find "$out/lib/qt/plugins" -type f \( -name '*.dylib' -o -name '*.so' \))
  else
    echo "  Warning: Qt detected but no plugins directory found in closure"
  fi

  # Bundle QML modules only when the derivation actually uses QtQml/QtQuick.
  # Non-UI derivations (e.g. using only QtCore/QtNetwork) don't need QML.
  qml_needed=0
  if [ "$IS_DARWIN" = "1" ]; then
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
  if [ "$qml_needed" = "1" ]; then
    echo "  Bundling QML modules..."
    while IFS= read -r storePath; do
      for candidate in "$storePath/lib/qt-6/qml" "$storePath/lib/qt-5/qml" "$storePath/share/qt-6/qml" "$storePath/share/qt-5/qml" "$storePath/lib/qt6/qml" "$storePath/lib/qt5/qml"; do
        if [ -d "$candidate" ]; then
          echo "  Found QML modules: $candidate"
          mkdir -p "$out/lib/qt/qml"
          # Merge contents (multiple store paths may contribute different modules)
          cp -aLn "$candidate"/. "$out/lib/qt/qml/" 2>/dev/null || true
          chmod -R u+w "$out/lib/qt/qml" 2>/dev/null || true
          qt_qml_found=1
        fi
      done
    done < "$CLOSURE_PATHS"

    if [ "$qt_qml_found" = "1" ]; then
      # Remove non-runtime files from QML modules to reduce bundle size:
      #   - designer/ dirs: Qt Designer metadata and images (large)
      #   - objects-Release/ dirs: CMake build artifacts
      #   - Qt/test/: test utilities
      #   - QtTest/: test framework
      #   - QmlTime/: testing helper
      #   - *.a, *.prl: static libraries and build metadata
      echo "  Cleaning non-runtime QML files..."
      qml_base="$out/lib/qt/qml"
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

      # Trace deps of shared libraries inside QML modules
      echo "  Tracing QML module dependencies..."
      while IFS= read -r qml_lib; do
        trace_deps "$qml_lib"
      done < <(find "$out/lib/qt/qml" -type f \( -name '*.dylib' -o -name '*.so' \))
    fi

    # Symlink app-shipped QML modules (in lib/ outside lib/qt/) into the
    # QML import path so they are discoverable alongside Qt's own modules.
    # QML modules are identified by the presence of a qmldir file.
    if [ -d "$out/lib/qt/qml" ] && [ -d "$out/lib" ]; then
      while IFS= read -r qmldir; do
        mod_dir="$(dirname "$qmldir")"
        # Relative path from $out/lib, e.g. "Logos/Theme"
        rel="${mod_dir#$out/lib/}"
        # Skip anything already under qt/
        [[ "$rel" == qt/* ]] && continue
        if [ ! -e "$out/lib/qt/qml/$rel" ]; then
          echo "  Symlinking app QML module: $rel"
          link_parent="$(dirname "$out/lib/qt/qml/$rel")"
          mkdir -p "$link_parent"
          target="$(realpath --relative-to="$link_parent" "$mod_dir")"
          ln -sf "$target" "$out/lib/qt/qml/$rel"
        fi
      done < <(find "$out/lib" -name 'qmldir' -not -path '*/qt/*')
    fi
  else
    echo "  Skipping QML bundling (no QtQml/QtQuick libraries detected)"
  fi

  # Create qt.conf so Qt can find plugins and QML modules relative to the binary
  if [ -d "$out/bin" ]; then
    echo "  Creating qt.conf..."
    cat > "$out/bin/qt.conf" <<QTCONF
[Paths]
Prefix = ..
Plugins = lib/qt/plugins
$([ "$qt_qml_found" = "1" ] && echo "QmlImports = lib/qt/qml")
QTCONF
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

if [ "$IS_DARWIN" = "1" ]; then

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
      elif is_system_lib "$interp_name"; then
        # System interpreter — rewrite to standard path
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
