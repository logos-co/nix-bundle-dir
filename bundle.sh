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
  for f in "$DRV_PATH"/bin/* "$DRV_PATH"/bin/.*; do
    [ -e "$f" ] || continue
    case "$(basename "$f")" in .|..) continue ;; esac
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

  while IFS= read -r storePath; do
    # Look for Qt plugin directories in every closure path and merge them.
    # Different Qt modules ship plugins in separate store paths (e.g. qtbase
    # has platforms/, qtsvg has iconengines/, qtnetwork has tls/, etc.), so we
    # must not stop after the first match.
    for candidate in "$storePath/lib/qt-6/plugins" "$storePath/lib/qt-5/plugins" "$storePath/share/qt-6/plugins" "$storePath/share/qt-5/plugins" "$storePath/lib/qt6/plugins" "$storePath/lib/qt5/plugins"; do
      if [ -d "$candidate" ]; then
        echo "  Found Qt plugins: $candidate"
        mkdir -p "$out/lib/qt/plugins"
        cp -aLn "$candidate"/. "$out/lib/qt/plugins/" 2>/dev/null || true
        chmod -R u+w "$out/lib/qt/plugins" 2>/dev/null || true
        qt_plugins_found=1
        break  # only one candidate per store path
      fi
    done
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

  # Create qt.conf so Qt can find plugins and QML modules relative to the binary.
  # LibraryExecutables / Data / Translations are set explicitly because the
  # compile-time defaults in some Qt builds (notably nixpkgs qt6) use paths
  # like "libexec/qt6", while our bundle lays things out at the Qt 6 defaults
  # ("libexec", ".", "translations") relative to Prefix.  QtWebEngine looks up
  # QtWebEngineProcess via LibraryExecutablesPath and its .pak/icudtl.dat via
  # DataPath + "/resources", so getting these wrong breaks the webview plugin.
  if [ -d "$out/bin" ]; then
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
if [ -d "$out/lib" ]; then
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
      echo "  Warning: patchelf --set-rpath failed for $f"

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
if [ -f "$out/lib/qt/plugins/platformthemes/libqxdgdesktopportal.so" ]; then _need_theme=1; fi

if [ "$IS_DARWIN" != "1" ] && [ -d "$out/bin" ] \
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
# keymap dispatch segfaults on a NULL xkb context.  This is the only reason
# this launcher exists.
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
    echo "  $base -> .$base.elf (launcher: XKB_CONFIG_ROOT)"
  done
fi

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
