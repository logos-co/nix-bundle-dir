# nix-bundle-dir

Bundle a Nix derivation and all its dependencies into a self-contained, portable directory.
Like [nix-bundle](https://github.com/matthewbauer/nix-bundle) and [nix-appimage](https://github.com/ralismark/nix-appimage), but produces a plain directory instead of a single-file executable, and works on both macOS and Linux.

## Getting started

To use this, you will need to have [Nix](https://nixos.org/) available with flakes enabled.
Then, run this via the [nix bundle](https://nixos.org/manual/nix/unstable/command-ref/new-cli/nix3-bundle.html) interface, replacing `nixpkgs#hello` with the flake you want to bundle:

```
$ nix bundle --bundler github:logos-co/nix-bundle-dir nixpkgs#hello
```

This produces a `hello-bundle` directory containing `bin/hello` and all its shared library dependencies:

```
$ ./hello-bundle/bin/hello
Hello, world!
```

The directory is fully self-contained — you can copy it to any compatible machine and it will work without Nix installed.

## Permissive mode

By default, the bundler fails if it finds `/nix/` paths embedded in binary data (e.g. compiled-in store paths). If you need to bundle packages that have such references and are okay with them, use the permissive bundler:

```
$ nix bundle --bundler github:logos-co/nix-bundle-dir#permissive nixpkgs#some-package
```

This turns those errors into warnings.

## Using as a library

The flake also exposes `lib.<system>.mkBundle` for more control:

```nix
let
  bundler = inputs.nix-bundle-dir;
  bundle = bundler.lib.${system}.mkBundle {
    drv = pkgs.hello;
    name = "hello";              # optional, defaults to drv.pname or drv.name
    excludeLibs = [ "libfoo*" ]; # optional, glob patterns for libs to skip
    useDefaultExcludes = true;    # optional, include the built-in exclude list (default: true)
    warnOnBinaryData = false;     # optional, treat embedded /nix/ strings as warnings instead of errors
  };
in bundle
```

See [mkBundle.nix](mkBundle.nix) for the full interface.

## Caveats

- **Graphics/OpenGL on Linux.** GPU driver libraries (`libGL`, `libEGL`, `libvulkan`, etc.) are excluded by default because they must match the host's hardware drivers. This is the same [well-known problem](https://github.com/NixOS/nixpkgs/issues/9415) that affects AppImages and other bundling approaches. You may need [nixGL](https://github.com/nix-community/nixGL) or similar.

- **glibc on Linux.** Core glibc libraries (`libc.so`, `libpthread.so`, `ld-linux*.so`, etc.) are excluded by default because they must match the host kernel. The bundled binaries will use the host's glibc.

- **Library-only packages.** If the derivation has no `bin/` directory, only `lib/` contents are bundled. This is useful for bundling shared libraries for use by other programs.

- **Shebangs.** Scripts with `#!/nix/store/...` shebangs are rewritten to `#!/usr/bin/env ...`, which requires the interpreter to be on `PATH`.

## Default library excludes

On Linux, a set of host-dependent libraries are excluded from bundling by default (inspired by the [AppImage excludelist](https://github.com/AppImageCommunity/pkg2appimage/blob/master/excludelist)):

- **glibc** — must match the host kernel
- **libstdc++/libgcc_s** — C++ runtime
- **GPU/graphics** — libGL, libEGL, libvulkan, libdrm, etc.
- **Display server** — libX11, libxcb, libwayland
- **Audio** — libasound, libjack, libpipewire
- **Fonts** — libfontconfig, libfreetype, libharfbuzz

On macOS, system libraries under `/usr/lib/` and `/System/Library/` are implicitly excluded since the dependency tracer only follows `/nix/store/` paths.

Set `useDefaultExcludes = false` in `mkBundle` to disable these and bundle everything.

## Under the hood

The bundler is a Nix derivation that runs a [six-phase shell script](bundle.sh):

1. **Copy** executables and libraries from the derivation's `bin/` and `lib/`
2. **Trace** shared library dependencies recursively (`otool` on macOS, `patchelf` on Linux), resolving `@rpath` references and searching the Nix closure
3. **Rewrite** all dynamic linking references to use relative paths (`@loader_path` on macOS, `$ORIGIN` on Linux) and remove all absolute rpaths
4. **Re-sign** Mach-O binaries (macOS only — required after any modification)
5. **Rewrite shebangs** from `/nix/store/...` to `#!/usr/bin/env ...`
6. **Verify** portability by copying the output to a temp directory (outside `/nix/store`) and checking that all references are portable

On Linux, phase 3 also does two things worth knowing about as output contract:

- It sets each ELF's interpreter to the path its **psABI mandates**
  (`/lib64/ld-linux-x86-64.so.2` on x86-64, `/lib/ld-linux-aarch64.so.1` on
  aarch64). Every glibc distro provides those exact paths, so the binaries run
  directly — there is no launcher indirection through `ld.so`. Note the two
  prefixes deliberately differ; `/lib64` for both would break arm64.
- It writes **`DT_RPATH` rather than `DT_RUNPATH`**, so bundled libraries take
  priority over a stale `LD_LIBRARY_PATH` instead of losing to it. A consequence
  worth stating: you can no longer override a *bundled* library via
  `LD_LIBRARY_PATH`. (`nixGL` still works — GPU libraries are on the exclude
  list, so they are absent from `$ORIGIN/../lib` and the search falls through to
  your environment.)

Some bundles additionally get a **launcher** at `bin/<name>`, with the real
binary beside it as `bin/.<name>.elf`. It is emitted only when `guiApp` is set
(the default) *and* the bundle needs an environment variable that its libraries
cannot derive on their own —
`XKB_CONFIG_ROOT` (libxkbcommon has its config root baked to a store path) or
`QT_QPA_PLATFORMTHEME` (the portal file-dialog theme must be chosen by name).
It is a plain `exec` wrapper, not an `ld.so` trampoline: `/proc/self/exe` is the
real binary and `argv[0]` is the launcher, so both identities are honest. If you
copy a bundle's `bin/` by hand, copy the dotfiles too.

Pass **`guiApp = false`** for a bundle that never puts anything on screen — a
headless CLI, a daemon — and its `bin/` entries stay plain binaries with no
companion. Leave it alone for anything that renders, *including a host process
that only loads UI plugins at runtime*: the bundler cannot detect that case (the
app's `DT_NEEDED` never names `libxkbcommon`, since the platform plugin
`dlopen`s it), and getting it wrong that way is a segfault rather than a
cosmetic wart.
