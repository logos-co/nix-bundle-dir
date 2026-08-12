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

### Libraries the host already ships (`hostLibs`, `hostBundle`)

A bundle that is loaded *into* another program — a plugin, a module installed
next to a host application — should not carry a second copy of the runtime that
host already provides. `hostLibs` is that list, and it applies on every target,
Windows/PE included:

```nix
mkBundle {
  drv = myModule;
  # Written in the TARGET's own spelling. There is one list, not one per
  # platform.
  hostLibs = [ "Qt*.dll" "libstdc++-*.dll" "libgcc_s_*.dll" "zlib1.dll" ];

  # Optional, PE only: the host's own bundle. Every name the bundler drops (or
  # accepts as the host's to satisfy) must be in that tree's application
  # directory — `bin/` if it has one, else the root — because that is the
  # directory Windows searches for the loading process.
  hostBundle = myHostApp;
}
```

**Only for a bundle that is loaded into something else.** On Windows a
host-provided DLL is found because the loader searches the *loading process's*
own directory. That is the host's directory when this bundle is a module
(`lib/<name>.dll`, no executable of its own) and it is the directory *this*
bundle's `.exe` sits in when the bundle has one — where the stripped DLLs no
longer are. So a `hostLibs` claim on a bundle that ships an executable is
**refused at build time**, wherever in the bundle that executable is: the check
is "does any PE in this tree have an executable image header", not "is there an
`.exe` in `bin/`". Measured: such a bundle dies with `0xC0000135` before
`main()` and prints nothing. It runs only if the deployment puts the host's
`bin\` somewhere the loader searches for that *process* — prepended to `PATH`,
or as the current directory, which is in the EXE search order too — and that is
not something a build-time check can see.

**What `hostLibs` may remove.** On ELF and Mach-O it filters what the bundler
*adds*: a traced dependency matching the list is not copied in. On Windows the
bundler also has to *delete*, because nixpkgs' `win-dll-link.sh` has already
staged the import closure into the derivation's own output before the bundler
sees it. Deleting is the more dangerous operation, so it is bounded by *who
declared what*:

- **A pattern you write deletes.** `hostLibs = [ "Qt*" ]` on a Qt plugin package
  removes that package's own `Qt6*.dll` too. That is the contract, not an
  accident — and `hostBundle` is how you make it checkable.
- **No bundler in this repo injects one that does.** `bundlers.<sys>.qtPlugin`
  appends `Qt*` for you, and only on non-Windows targets, where `hostLibs`
  cannot delete anything. That is a statement about this repo's bundlers, not
  about every caller: `nix-bundle-lgx` injects a list of its own and is kept off
  this path by routing rather than by rule.
- **Nothing is removed from `extraDirs`.** Those directories are named by you,
  one by one, as "carry this"; a name glob does not overrule that. Note the
  guarantee is one-directional: the sweep may still STAGE a dependency into a
  declared directory when the importer lives there, which is what makes such a
  bundle loadable.
- **A strip that would empty the bundle fails the build.**

Do not read anything into the shape of the patterns. Cross-platform spellings
*can* over-match — `libcrypto*` matches `libcrypto-3-x64.dll` — and the safety
comes from the rules above, from `hostBundle`, and from the log naming every
dropped file.

**The host must also LOOK there.** A stripped module finds the host's DLLs
because Windows searches the *loading process's own directory*, and some
`LoadLibraryEx` flags remove precisely that directory from the search.

Measured on Windows 11 x86-64 (AMD64) against the **real**
`logos-package_manager-module` — `packages.x86_64-windows.lib`, bundled by this
bundler: 19 PEs examined, 16 removed, 3 kept — a host bundle shipping those 16
in its `bin\`, and the *unstripped* bundle of the same module as the control.
The loading process's current directory is a scratch directory holding none of
the DLLs unless a row says otherwise:

| flags | what it means | stripped | control | what the pair says |
|---|---|---|---|---|
| `0x1100` | `…DLL_LOAD_DIR｜…DEFAULT_DIRS` | **loads** | loads | the mode Logos uses; the strip is invisible |
| `0x0008` | `LOAD_WITH_ALTERED_SEARCH_PATH` | fails, 126 | **loads** | the strip, and only the strip |
| `0x0008` | same, CWD = the host's own `bin\` | **loads** | — | the current directory is still in that order |
| `0x0000` | default search order | fails, 126 | fails, 126 | *not* the strip |
| `0x0100` | `…SEARCH_DLL_LOAD_DIR` alone | fails, 126 | fails, 126 | *not* the strip |
| `0x1000` | `…SEARCH_DEFAULT_DIRS` alone | fails, 126 | fails, 126 | *not* the strip |
| `0x1100` | host missing one claimed DLL | fails, 126 | **loads** | the claim is load-bearing |

`0x1100` is what logos-module's `preloadPluginWithOwnDirSearch`
(`src/win_dll_search.h`) passes, which is why Logos modules may be stripped.

Read the table as a statement about which directories a mode searches, not as
one verdict per flag — the three "not the strip" rows are why. A real module
keeps private DLLs of its own beside it, and the default order does not search a
loaded DLL's own directory at all, so `0x0000` fails on the *unstripped* bundle
too; `0x0100` and `0x1000` each name only half of what is needed. And `0x0008`
replaces the application directory while leaving the rest of the standard order
in place, current directory included — so the same host, started from its own
`bin\`, loads the same stripped module through `0x0008`.

(An earlier revision of this table was measured on a synthetic single-DLL module
and reported `0x0000` as loading. That is true only for a module with no private
dependencies of its own, which no real Logos module is.)

Nothing at build time can see which mode a host will use, or where it will be
started from, so this is a property of the host you must check once, by hand —
`hostBundle` checks that the DLL is *there*, not that anyone will look.

Every `hostLibs` entry is a promise about another package's output, and on
Windows a broken promise is silent — `LoadLibrary` fails with
`ERROR_MOD_NOT_FOUND` (126) and Qt reports only "The specified module could not
be found", naming the *plugin* rather than the DLL that is absent. `hostBundle`
turns that promise into a build-time check; without it the build still works and
the log lists every claim, marked `UNVERIFIED`. Passing `hostBundle` with an
empty `hostLibs`, or on a non-Windows target, is refused rather than ignored.

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
It is a plain `exec` wrapper, not an `ld.so` trampoline, so `/proc/self/exe` is
the real binary rather than the loader. `argv[0]` is the launcher **where the
host shell can preserve it** — the wrapper uses `exec -a` if its own `/bin/sh`
supports it, else bridges through `bash`; on a host with neither (no `exec -a`,
no `bash`) it falls back to a plain `exec` and `argv[0]` becomes the real ELF
path. If you copy a bundle's `bin/` by hand, copy the dotfiles too.

Pass **`guiApp = false`** for a bundle that never puts anything on screen — a
headless CLI, a daemon — and its `bin/` entries stay plain binaries with no
companion. Leave it alone for anything that renders, *including a host process
that only loads UI plugins at runtime*: the bundler cannot detect that case (the
app's `DT_NEEDED` never names `libxkbcommon`, since the platform plugin
`dlopen`s it), and getting it wrong that way is a segfault rather than a
cosmetic wart.
