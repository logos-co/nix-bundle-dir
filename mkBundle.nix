{ pkgs }:

{ drv
, name ? drv.pname or drv.name or "bundle"
, systemLibs ? []
# Libraries the RUNTIME HOST already provides, which this bundle must therefore
# not carry. Applied on every target: ELF, Mach-O and — since this argument
# started being honoured on the PE path — Windows.
#
# ONE list for all three, with the caller writing the spelling that matches the
# target's own file names. What a caller writes for a Logos module bundled for
# Windows:
#
#   hostLibs = [ "Qt*.dll" "libcrypto-*.dll" "libssl-*.dll"
#                "libstdc++-*.dll" "libgcc_s_*.dll" "zlib1.dll" ... ];
#   hostBundle = logos-basecamp.packages.x86_64-windows.default;
#
# and for the same module on Linux:
#
#   hostLibs = [ "libQt*" "libcrypto.so*" "libssl.so*" "libz.so*" ... ];
#
# The spellings do not transfer and are not meant to: `libz*` never matches
# `zlib1.dll`, `libcrypto*` never matches `libcrypto-3-x64.dll`. A list written
# for the wrong platform therefore strips LESS than intended rather than more,
# which on Windows is inert (a duplicate of a DLL the host has already loaded
# is never consulted) where the opposite is fatal. bundle.sh says so in the log
# when a declared list matches nothing at all. See the long note above
# `pe_is_host_lib` in bundle.sh for why the LIST is shared and only the MATCH
# is platform-specific.
, hostLibs ? []
# The host's own assembled bundle, used to CHECK `hostLibs` rather than take it
# on trust. PE path only.
#
# Every hostLibs entry is a promise about another repo's output, and on Windows
# a broken promise is silent: the module fails to load with ERROR_MOD_NOT_FOUND
# (126) and Qt reports only "The specified module could not be found", naming
# the plugin rather than the DLL that is absent. Point this at the tree the
# host process actually runs from and every name the bundler drops — or accepts
# as the host's to satisfy — has to be present in that tree's application
# directory (`bin/` if it has one, else the root, one level deep, because that
# is the directory Windows searches for the loading process).
#
# Left null the strip still happens and the claims are listed in the log,
# flagged UNVERIFIED. Optional rather than required because a module package's
# host can be a repo it has no other reason to depend on, and making this
# mandatory would put the strip out of reach of the packages that need it most.
#
# Not consulted on ELF/Mach-O: those paths are unchanged by this argument, down
# to the byte, and extending the check to them is a separate change with its
# own evidence.
, hostBundle ? null
, extraDirs ? []
, extraClosurePaths ? []
, useDefaultSystemLibs ? true
, warnOnBinaryData ? false
# Does the bundled derivation target Windows (PE), rather than ELF/Mach-O?
#
# Normally leave this null: it is READ OFF `drv` (see `targetStdenv` below) and
# a caller cannot get it wrong. Set it only when `drv` is not an
# `stdenv.mkDerivation` result at all — a bare `builtins.storePath`, a
# hand-rolled `derivation` — because those carry no stdenv to read, and the
# bundler will otherwise have to fall back to inspecting the artefacts.
, windowsTarget ? null
# Does anything in this bundle put a GUI on screen?
#
# It decides whether bin/ entries get an environment launcher. Two bundled
# libraries need a variable set that they cannot derive from their own
# location: libxkbcommon has its config root baked to a store path (without
# XKB_CONFIG_ROOT a Qt app segfaults in keymap dispatch on Wayland — measured,
# not theoretical), and the xdg-desktop-portal file-dialog theme has to be
# chosen by name. Both only matter once a Qt GUI platform plugin is loaded.
#
# It is a declaration rather than something the bundler detects, because
# detection cannot work: the app's own DT_NEEDED never mentions libxkbcommon
# (the platform plugin dlopens it), and a host process like `ui-host` shows no
# GUI symbol at all yet renders QML through plugins it loads at runtime.
# Guessing wrong in that direction is a segfault, so the caller — who knows
# what it built — says.
#
# Default true is the safe direction: a needless launcher costs a hidden
# companion ELF, a missing one costs a crash.
, guiApp ? true
}:

let
  # Extra closure paths allow the caller to inject store paths into the
  # dependency closure that the bundler scans for Qt plugins, QML modules,
  # and shared libraries.  This is needed when the derivation's output
  # doesn't reference a dependency directly (e.g. a Qt module used only by
  # portable-bundled plugins whose nix-store references were stripped).
  closureInfo = pkgs.closureInfo { rootPaths = [ drv ] ++ extraClosurePaths; };
  isDarwin = pkgs.stdenv.isDarwin;

  # ---------------------------------------------------------------------------
  # What platform is the BUNDLED DERIVATION for?
  # ---------------------------------------------------------------------------
  # NOT `pkgs`. `isDarwin` above reads the BUILD platform, which is correct for
  # it (it selects otool/patchelf, which run on the builder) and useless here:
  # bundlers are deliberately selected by the build system — logos-basecamp uses
  # `nix-bundle-dir.bundlers.${buildSystem}.qtApp` so that the builder gets an
  # ELF bundler and not a PE it cannot execute — so nix-bundle-dir's own `pkgs`
  # is always the native one, even when the thing being bundled is a Windows
  # cross build. That is why an earlier attempt reached for artefact sniffing.
  #
  # But `drv` is not `pkgs`. Every `stdenv.mkDerivation` result carries its own
  # stdenv, and a cross-built one carries the CROSS stdenv. Measured, not
  # assumed (nix eval, x86_64-linux):
  #   pkgsCross.mingwW64.hello.stdenv.hostPlatform.isWindows       => true
  #   pkgsCross.mingwW64.qt6.qtbase.stdenv.hostPlatform.isWindows  => true
  #   hello.stdenv.hostPlatform.isWindows                          => false
  #   (pkgsCross.mingwW64.runCommand "x" {} "").stdenv.hostPlatform.isWindows
  #                                                                => true
  #   (symlinkJoin { ... }) ? stdenv                               => true
  # So mkDerivation, runCommand and symlinkJoin all answer, which covers every
  # shape this bundler is handed today.
  #
  # `or null` rather than a default: a drv with no stdenv must reach bundle.sh
  # as "unknown" and be handled there, loudly. Defaulting it to false would
  # silently put a Windows bundle on the Unix path, which is the exact class of
  # bug this branch exists to remove.
  targetStdenv = drv.stdenv or null;
  derivedIsWindows =
    if targetStdenv == null then null
    else targetStdenv.hostPlatform.isWindows or null;
  isWindowsTarget = if windowsTarget != null then windowsTarget else derivedIsWindows;
  isWindowsStr =
    if isWindowsTarget == null then "unknown"
    else if isWindowsTarget then "1" else "0";

  # The PE import-table reader, taken from the TARGET's own toolchain.
  #
  # Not `objdump` off PATH — but NOT because the ambient objdump is known to be
  # blind. That is what this comment used to claim, and it is not what is
  # measured. On x86_64-linux the ambient binutils supports pei-x86-64
  # (`objdump --info` lists pei-i386, pe-x86-64, pei-x86-64). On aarch64-darwin
  # the objdump that mkBundle already puts on PATH for every Darwin build —
  # darwin.cctools, i.e. LLVM objdump — also reads PE: measured against a real
  # PE32+ DLL from this store (mcfgthread-x86_64-w64-mingw32), it printed
  # `file format coff-x86-64` and the file's DLL Name entries. So the honest
  # statement is that neither reader has been observed to fail.
  #
  # The reason to take the reader from the target anyway is that "does this
  # builder's objdump happen to have a PE target?" is a property of the
  # BUILDER's toolchain, which nothing in this expression controls and which
  # changes under us; and the failure mode when the answer is no is a silent
  # zero — an empty import list, exit 0 — which is indistinguishable from a
  # complete bundle. Choosing the reader by target removes the question rather
  # than betting on its current answer, and pe_reader_control in bundle.sh
  # proves the chosen reader actually reads a PE before any zero it returns is
  # believed, whichever reader that turns out to be.
  #
  # `targetStdenv.cc.bintools.bintools` is the raw binutils derivation (the
  # outer two are wrappers); for pkgsCross.mingwW64 it evaluates to
  # x86_64-w64-mingw32-binutils-2.46, whose bin/ holds
  # x86_64-w64-mingw32-objdump.
  crossBintools =
    if isWindowsStr == "1" && targetStdenv != null
       && (targetStdenv.hostPlatform.isWindows or false)
    then targetStdenv.cc.bintools.bintools or null
    else null;
  peObjdump =
    if crossBintools == null then ""
    else "${crossBintools}/bin/${targetStdenv.cc.targetPrefix or ""}objdump";

  # Default system libraries that should not be bundled.
  # Based on the AppImage excludelist:
  # https://github.com/AppImageCommunity/pkg2appimage/blob/master/excludelist
  #
  # On macOS, system libraries live outside /nix/store (/usr/lib, /System/Library)
  # so they are already implicitly excluded by the dependency tracer. These defaults
  # only matter for Linux, where Nix builds its own copies of system libraries.
  defaultSystemLibs = pkgs.lib.optionals isDarwin [
    # macOS system libraries — provided by the OS at /usr/lib/
    "libSystem.B.dylib"
    "libc++.*.dylib"
  ] ++ pkgs.lib.optionals (!isDarwin) [
    # glibc — kernel interface, must match host
    "ld-linux*.so*"
    "libanl.so*"
    "libBrokenLocale.so*"
    "libc.so*"
    "libdl.so*"
    "libm.so*"
    "libmvec.so*"
    "libnss_compat.so*"
    "libnss_dns.so*"
    "libnss_files.so*"
    "libnss_hesiod.so*"
    "libnss_nisplus.so*"
    "libnss_nis.so*"
    "libpthread.so*"
    "libresolv.so*"
    "librt.so*"
    "libthread_db.so*"
    "libutil.so*"

    # C++ runtime
    "libstdc++.so*"
    "libgcc_s.so*"

    # GPU / graphics driver interface — must match host hardware
    "libGL.so*"
    "libEGL.so*"
    "libGLX.so*"
    "libGLdispatch.so*"
    "libOpenGL.so*"
    "libGLESv2.so*"
    "libdrm.so*"
    "libglapi.so*"
    "libgbm.so*"
    "libvulkan.so*"

    # Display server protocol — must match running server
    "libX11.so*"
    "libX11-xcb.so*"
    "libxcb.so*"
    "libxcb-dri2.so*"
    "libxcb-dri3.so*"
    "libwayland-client.so*"

    # Audio — must match host audio subsystem
    "libasound.so*"
    "libjack.so*"
    "libpipewire-*.so*"

    # Font rendering — must access host font config/cache
    "libfontconfig.so*"
    "libfreetype.so*"
    "libharfbuzz.so*"
    "libfribidi.so*"
  ];

  allSystemLibs = (if useDefaultSystemLibs then defaultSystemLibs else []) ++ systemLibs;
in

pkgs.stdenv.mkDerivation {
  pname = "${name}-bundle";
  version = drv.version or "0";

  src = null;
  dontUnpack = true;
  dontFixup = true;

  nativeBuildInputs = with pkgs; [
    coreutils
    findutils
    file
  ] ++ pkgs.lib.optionals isDarwin [
    darwin.cctools
    darwin.sigtool
  ] ++ pkgs.lib.optionals (!isDarwin) [
    patchelf
  ]
  # PE bundles need an import-table reader, and only PE bundles do. Both
  # entries are conditional so a Unix bundle's build inputs stay as they were.
  ++ pkgs.lib.optionals (crossBintools != null) [ crossBintools ]
  ++ pkgs.lib.optionals (isWindowsStr != "0" && crossBintools == null && !isDarwin) [
    # Fallback for `windowsTarget = true` on a drv with no cross toolchain to
    # borrow from, and for the unknown-target case. Less load-bearing than it
    # looks — see the PE_OBJDUMP note above: on the builders measured so far the
    # ambient objdump reads PE perfectly well, so this is a belt for a case
    # nobody has yet observed rather than a known-broken path. bundle.sh proves
    # the reader works before it trusts any zero it produces, so a wrong objdump
    # here is a loud failure rather than an empty bundle.
    binutils
  ];

  # EVERY bundle's store path changes when this branch lands, on every platform,
  # even where the produced tree is byte-for-byte what it was. That is worth
  # stating because a consumer that RECORDS a bundle's path — an .lgx built from
  # one, a pinned artefact — sees a new hash and must re-fetch.
  #
  # It is also unavoidable and is not caused by the two PE env vars below.
  # `buildPhase` names ${./bundle.sh} by store path, so the script IS an input:
  # any edit to the bundler rehashes every bundle it produces. Dropping
  # IS_WINDOWS/PE_OBJDUMP on the Unix path would buy nothing and would cost the
  # one distinction bundle.sh's Phase 1c relies on ("0" = Nix says Unix,
  # "unknown" = the drv carries no stdenv to ask).
  CLOSURE_PATHS = "${closureInfo}/store-paths";
  DRV_PATH = "${drv}";
  IS_DARWIN = if isDarwin then "1" else "0";
  IS_WINDOWS = isWindowsStr;
  PE_OBJDUMP = peObjdump;
  SYSTEM_LIBS = builtins.concatStringsSep "\n" allSystemLibs;
  HOST_LIBS = builtins.concatStringsSep "\n" hostLibs;
  # Empty string, not an absent variable, so bundle.sh's `${HOST_BUNDLE:-}`
  # tests read the same on every platform. Interpolating the derivation is what
  # puts it in the build's inputs, which is required: the bundler reads the
  # host's tree at build time.
  HOST_BUNDLE = if hostBundle == null then "" else "${hostBundle}";
  EXTRA_DIRS = builtins.concatStringsSep "\n" extraDirs;
  WARN_ON_BINARY_DATA = if warnOnBinaryData then "1" else "0";
  GUI_APP = if guiApp then "1" else "0";

  buildPhase = ''
    bash ${./bundle.sh}
  '';

  installPhase = "true";
}
