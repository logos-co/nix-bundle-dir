{ pkgs }:

{ drv
, name ? drv.pname or drv.name or "bundle"
, systemLibs ? []
, hostLibs ? []
, extraDirs ? []
, useDefaultSystemLibs ? true
, warnOnBinaryData ? false
}:

let
  closureInfo = pkgs.closureInfo { rootPaths = [ drv ]; };
  isDarwin = pkgs.stdenv.isDarwin;

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
  ];

  CLOSURE_PATHS = "${closureInfo}/store-paths";
  DRV_PATH = "${drv}";
  IS_DARWIN = if isDarwin then "1" else "0";
  SYSTEM_LIBS = builtins.concatStringsSep "\n" allSystemLibs;
  HOST_LIBS = builtins.concatStringsSep "\n" hostLibs;
  EXTRA_DIRS = builtins.concatStringsSep "\n" extraDirs;
  WARN_ON_BINARY_DATA = if warnOnBinaryData then "1" else "0";

  buildPhase = ''
    bash ${./bundle.sh}
  '';

  installPhase = "true";
}
