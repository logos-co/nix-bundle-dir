# The Windows/PE `hostLibs` contract, as buildable subjects.
#
# `hostLibs` names libraries the RUNTIME HOST already ships, so the bundle must
# not carry them. It was accepted by mkBundle.nix and applied on the Unix path
# from the start; on the PE path it reached the derivation as HOST_LIBS and
# then changed nothing, which for a Logos module meant ~36 MB of Qt, OpenSSL
# and C++ runtime (Qt6Core.dll alone is 15 MB) inside every package.
#
# THREE halves, and no two of them work without the third.
#
#   1. the STRIP, which removes what is already staged;
#   2. the SKIP, at the import level, so the closure cannot put it back;
#   3. the ACCEPTANCE, in Phase 6, without which the verifier fails the build
#      over the very DLLs the strip was told not to carry.
#
# And the rule that BOUNDS the strip, because deleting is not the same
# operation as declining to add. On ELF and Mach-O `hostLibs` only ever filters
# what `trace_deps` copies IN; on Windows the import closure has already been
# staged into the derivation's own output by nixpkgs' win-dll-link.sh before
# the bundler runs, so the PE path has to delete. The rule is about
# DECLARATION, and infers nothing about any file:
#
#   * a pattern the CALLER wrote deletes — including one that matches the
#     package's own build products;
#   * a pattern a BUNDLER injects never reaches the PE path (flake.nix's
#     `qtPlugin` appends `Qt*` only on a non-Windows target);
#   * a directory named in `extraDirs` is never touched.
#
# The fixtures below therefore no longer distinguish LINKED from COPIED DLLs as
# a matter of policy — `moduleLinked` and `moduleCopied` are stripped alike, and
# a subject asserts exactly that. An earlier revision bounded the strip by that
# distinction (regular file = the build produced it, symlink = a dependency
# travelling with it) and it fails on the shape that matters: in the real
# `logos-package_manager-module` x86_64-w64-mingw32 output, 8 of the 19 DLLs in
# lib/ — icudt76, icuuc76, libstdc++-6, libgcc_s_seh-1, libmcfgthread-2,
# libsodium-26, zlib1 and more — are REGULAR FILES, so the rule called the whole
# host runtime payload and stripped nothing.
#
# The fourth part is `hostBundle`, which makes the list checkable rather than
# declared. Every hostLibs entry is a promise about another repo's output, and
# a broken promise is silent on Windows: LoadLibrary fails with
# ERROR_MOD_NOT_FOUND (126) and Qt reports only "The specified module could not
# be found", naming the PLUGIN rather than the missing DLL.
#
# Why these are here and not in smoke.sh's `nix bundle --bundler` calls:
# smoke.sh drives `nixpkgs#hello`, which cannot express hostLibs, hostBundle, a
# cross target, or a module-shaped output at all. smoke.sh DOES build these
# subjects — see the pe-hostlibs section at the end of it — because a check
# nothing runs is not a check.
#
# x86_64-linux only, by the caller's gate in flake.nix: every subject is a
# `pkgsCross.mingwW64` build, and the mingw toolchain is substitutable there.
#
# `qtPluginBundler` is flake.nix's own `bundlers.<sys>.qtPlugin`, passed in
# because one subject is about what THAT function injects, which cannot be
# reproduced by calling mkBundle directly.
{ pkgs, mkBundle, qtPluginBundler }:

let
  mingw = pkgs.pkgsCross.mingwW64;

  # The C++ runtime DLLs a mingw C++ module imports. Chosen because they are
  # what a real Logos module actually depends on, they are genuinely
  # host-provided in the workspace's Windows layout, and — the part that makes
  # them a fair fixture — a PE embeds no /nix/store strings, so Nix records no
  # reference to the store paths that hold them. They reach a bundle only
  # through extraClosurePaths, which is exactly the cost `hostLibs` removes.
  gccLib = mingw.stdenv.cc.cc.lib;
  mcfg = mingw.windows.mcfgthreads;
  dllDir = "${gccLib}/x86_64-w64-mingw32/lib";
  mcfgDll = "${mcfg}/bin/libmcfgthread-2.dll";
  hostDlls = [ "libstdc++-*.dll" "libgcc_s_*.dll" "libmcfgthread-*.dll" ];

  # Real C++, not a hand-written stub. A file that merely begins with "MZ" is
  # never classified as a PE by `file`, so every shape in bundle.sh degrades to
  # "no PE here" and a fixture built that way measures nothing.
  pluginSrc = pkgs.writeText "demo_plugin.cpp" ''
    #include <string>
    #include <stdexcept>
    extern "C" __declspec(dllexport) const char *demo_name() {
      static std::string s;
      try { s = std::string("demo") + std::to_string(42); throw std::runtime_error("x"); }
      catch (const std::exception &e) { s += e.what(); }
      return s.c_str();
    }
  '';
  appSrc = pkgs.writeText "demo_app.cpp" ''
    #include <string>
    #include <cstdio>
    int main() { std::string s = "hi"; std::printf("%s\n", s.c_str()); return 0; }
  '';

  # `dontFixup`, so each fixture is exactly what this file says it is: the
  # mingw stdenv's own win-dll-link hook would otherwise stage DLLs on its own
  # schedule and the subjects would be asserting about its output rather than
  # about the bundler's.

  # SHAPE 1: a module. `lib/<name>_plugin.dll` and NOTHING else -- no bin/.
  # This is the shape nix-bundle-lgx feeds through the bundler, and the one
  # the PE path has been blind on before.
  moduleBare = mingw.stdenv.mkDerivation {
    name = "hostlibs-module-bare";
    dontUnpack = true;
    dontFixup = true;
    buildPhase = "$CXX -shared -o demo_plugin.dll ${pluginSrc}";
    installPhase = "mkdir -p $out/lib && cp demo_plugin.dll $out/lib/";
  };

  # SHAPE 1b: the same module AFTER an upstream `linkDLLsInfolder "$out/lib"`,
  # i.e. with the whole import closure LINKED in beside the plugin. This is
  # what the workspace's module derivations really produce, and it is the one
  # the strip has to shrink -- import-level skipping alone would leave every
  # one of these files in place.
  moduleLinked = mingw.stdenv.mkDerivation {
    name = "hostlibs-module-linked";
    dontUnpack = true;
    dontFixup = true;
    buildPhase = "$CXX -shared -o demo_plugin.dll ${pluginSrc}";
    installPhase = ''
      mkdir -p $out/lib && cp demo_plugin.dll $out/lib/
      ln -s ${dllDir}/libstdc++-6.dll ${dllDir}/libgcc_s_seh-1.dll ${mcfgDll} $out/lib/
    '';
  };

  # SHAPE 1c: the same names, COPIED into the derivation's own output rather
  # than linked -- which is what the real module output looks like for most of
  # its runtime DLLs. Byte-for-byte the same DLLs; under the declaration rule
  # the bundler treats them identically, and `copiesStrippedToo` asserts it.
  moduleCopied = mingw.stdenv.mkDerivation {
    name = "hostlibs-module-copied";
    dontUnpack = true;
    dontFixup = true;
    buildPhase = "$CXX -shared -o demo_plugin.dll ${pluginSrc}";
    installPhase = ''
      mkdir -p $out/lib && cp demo_plugin.dll $out/lib/
      cp ${dllDir}/libstdc++-6.dll ${dllDir}/libgcc_s_seh-1.dll ${mcfgDll} $out/lib/
      chmod +w $out/lib/*.dll
    '';
  };

  # SHAPE 1d: a module carrying a DLL in a directory the caller asked for by
  # name. `extraDirs` is an explicit "carry this", and the strip walked the
  # whole of $out with no exception for it -- measured: the entry shipped
  # EMPTY, rc=0.
  moduleWithAssets = mingw.stdenv.mkDerivation {
    name = "hostlibs-module-assets";
    dontUnpack = true;
    dontFixup = true;
    buildPhase = "$CXX -shared -o demo_plugin.dll ${pluginSrc}";
    installPhase = ''
      mkdir -p $out/lib $out/share/assets
      cp demo_plugin.dll $out/lib/
      ln -s ${dllDir}/libstdc++-6.dll ${dllDir}/libgcc_s_seh-1.dll ${mcfgDll} $out/lib/
      cp ${dllDir}/libstdc++-6.dll $out/share/assets/
      chmod +w $out/share/assets/libstdc++-6.dll
    '';
  };

  # SHAPE 1d2: the same extraDirs entry, but with an IMPORTER inside it, and a
  # bin/ for the sweep to mirror into. `extraDirs` keeps the host-matched DLL
  # (rule 2); the sweep then sees an importer whose dependency sits beside it,
  # and its beside-the-importer MIRROR copies that dependency into bin/ -- out
  # of the one directory the strip may not touch and into one where nothing
  # keeps it. Measured on the revision before the sweep's two tests were
  # reordered: the strip printed `- bin/libstdc++-6.dll (host-provided)`, the
  # sweep printed `~ libstdc++-6.dll mirrored into bin/ from share/assets`, and
  # the finished bundle shipped bin/libstdc++-6.dll, exit 0. The comment on
  # `pe_strip_host_libs` asserted at the time that nothing hostLibs matches is
  # ever staged "into an extraDir or anywhere else".
  #
  # bin/ holds the plugin rather than being empty so the shape is a real library
  # package rather than a directory that exists to make a code path reachable.
  moduleAssetsImporter = mingw.stdenv.mkDerivation {
    name = "hostlibs-module-assets-importer";
    dontUnpack = true;
    dontFixup = true;
    buildPhase = "$CXX -shared -o demo_plugin.dll ${pluginSrc}";
    installPhase = ''
      mkdir -p $out/lib $out/bin $out/share/assets
      cp demo_plugin.dll $out/lib/
      cp demo_plugin.dll $out/bin/
      cp demo_plugin.dll $out/share/assets/asset_plugin.dll
      cp ${dllDir}/libstdc++-6.dll ${dllDir}/libgcc_s_seh-1.dll ${mcfgDll} $out/share/assets/
      chmod +w $out/share/assets/*.dll
    '';
  };

  # SHAPE 1e: a library package's bin/ -- DLLs and no executable, which is what
  # `linkDLLsInfolder "$out/bin"` leaves behind. Nothing in it can be a process,
  # so the app-shape refusal does not apply, and it is the shape that reaches
  # Phase 6's "this bin/ entry is missing because THIS build removed it" arm.
  moduleBinDlls = mingw.stdenv.mkDerivation {
    name = "hostlibs-module-bin-dlls";
    dontUnpack = true;
    dontFixup = true;
    buildPhase = "$CXX -shared -o demo_plugin.dll ${pluginSrc}";
    installPhase = ''
      mkdir -p $out/lib $out/bin && cp demo_plugin.dll $out/lib/
      ln -s ${dllDir}/libstdc++-6.dll ${dllDir}/libgcc_s_seh-1.dll ${mcfgDll} $out/bin/
    '';
  };

  # SHAPE 1f: a module whose OWN BUILD produces a PE named like a Qt library --
  # the shape of every Qt plugin package. Used twice, for the two halves of the
  # declaration rule: a CALLER's `Qt*.dll` removes this Qt6Core.dll, and the
  # `qtPlugin` bundler's injected `Qt*` does not.
  qtNamedModule = mingw.stdenv.mkDerivation {
    name = "hostlibs-qt-named-module";
    dontUnpack = true;
    dontFixup = true;
    buildPhase = ''
      $CXX -shared -o demo_plugin.dll ${pluginSrc}
      $CXX -shared -o Qt6Core.dll ${pluginSrc}
    '';
    installPhase = ''
      mkdir -p $out/lib && cp demo_plugin.dll Qt6Core.dll $out/lib/
      ln -s ${dllDir}/libstdc++-6.dll ${dllDir}/libgcc_s_seh-1.dll ${mcfgDll} $out/lib/
    '';
  };

  # SHAPE 1g: a bin/ holding a DIRECTORY named like a Qt DLL. Contrived-looking
  # and not invented: it is the one shape that still reaches the
  # `pe_is_host_lib "$qt_lib_name"` arm in Qt detection, because the strip walks
  # `-type f` and cannot remove a directory while the detection loop's `[ -e ]`
  # counts one. bundle.sh has carried three different wrong claims about that
  # arm's reachability; this is what makes the current one checkable.
  qtDirModule = mingw.stdenv.mkDerivation {
    name = "hostlibs-qt-dir-module";
    dontUnpack = true;
    dontFixup = true;
    buildPhase = "$CXX -shared -o demo_plugin.dll ${pluginSrc}";
    installPhase = ''
      mkdir -p $out/lib $out/bin/Qt6Core.dll
      cp demo_plugin.dll $out/lib/
      ln -s ${dllDir}/libstdc++-6.dll ${dllDir}/libgcc_s_seh-1.dll ${mcfgDll} $out/lib/
    '';
  };

  # SHAPE 2: an application. It has an executable of its own, so it can BE the
  # process -- and then the directory Windows searches is this bundle's bin/,
  # not the host's. Every hostLibs claim on this shape is refused.
  appLinked = mingw.stdenv.mkDerivation {
    name = "hostlibs-app-linked";
    dontUnpack = true;
    dontFixup = true;
    buildPhase = "$CXX -o demo_app.exe ${appSrc}";
    installPhase = ''
      mkdir -p $out/bin && cp demo_app.exe $out/bin/
      ln -s ${dllDir}/libstdc++-6.dll ${dllDir}/libgcc_s_seh-1.dll ${mcfgDll} $out/bin/
    '';
  };

  # SHAPE 2b: an executable that is NOT in an application directory. There is no
  # bin/ at all, so the refusal's scan used to return before looking at anything
  # -- it resolved bin/ and gave up when there was none -- while README.md and
  # mkBundle.nix both said, without qualification, that a bundle shipping an
  # executable is refused. The shape is not a curiosity: the loader searches the
  # directory the .exe is in, which here is lib/, and lib/ is exactly what the
  # strip empties.
  appInLib = mingw.stdenv.mkDerivation {
    name = "hostlibs-app-in-lib";
    dontUnpack = true;
    dontFixup = true;
    buildPhase = ''
      $CXX -shared -o demo_plugin.dll ${pluginSrc}
      $CXX -o demo_app.exe ${appSrc}
    '';
    installPhase = ''
      mkdir -p $out/lib && cp demo_plugin.dll demo_app.exe $out/lib/
      ln -s ${dllDir}/libstdc++-6.dll ${dllDir}/libgcc_s_seh-1.dll ${mcfgDll} $out/lib/
    '';
  };

  # A plain copy of the app, for building the host bundle out of.
  appPlain = mingw.stdenv.mkDerivation {
    name = "hostlibs-app-plain";
    dontUnpack = true;
    dontFixup = true;
    buildPhase = "$CXX -o demo_app.exe ${appSrc}";
    installPhase = "mkdir -p $out/bin && cp demo_app.exe $out/bin/";
  };

  # The host's own bundle: the tree whose application directory the host
  # process runs from. `bin/`, because that is the directory Windows searches
  # for the loading process.
  hostGood = pkgs.runCommand "hostlibs-host-good" { } ''
    mkdir -p $out/bin
    cp ${dllDir}/libstdc++-6.dll ${dllDir}/libgcc_s_seh-1.dll ${mcfgDll} $out/bin/
    cp ${appPlain}/bin/demo_app.exe $out/bin/host.exe
  '';

  # The same host, plus a Qt6Core.dll -- for the subject where the CALLER
  # declares `Qt*.dll` and the bundle's own Qt-named DLL is therefore dropped.
  hostWithQt = pkgs.runCommand "hostlibs-host-qt" { } ''
    mkdir -p $out/bin
    cp ${dllDir}/libstdc++-6.dll ${dllDir}/libgcc_s_seh-1.dll ${mcfgDll} $out/bin/
    cp ${qtNamedModule}/lib/Qt6Core.dll $out/bin/
    cp ${appPlain}/bin/demo_app.exe $out/bin/host.exe
  '';

  # The same host with libgcc_s_seh-1.dll in lib/ instead of bin/. Not a
  # contrived shape: "it is in the host bundle somewhere" is precisely the
  # mistake, and it is invisible to any check that greps the whole tree.
  hostMisplaced = pkgs.runCommand "hostlibs-host-misplaced" { } ''
    mkdir -p $out/bin $out/lib
    cp ${dllDir}/libstdc++-6.dll ${mcfgDll} $out/bin/
    cp ${appPlain}/bin/demo_app.exe $out/bin/host.exe
    cp ${dllDir}/libgcc_s_seh-1.dll $out/lib/
  '';

  # A host bundle with no PE in its application directory at all -- a wrong
  # store path, a source tree instead of a bundle. Every claim checked against
  # it would be checked against nothing, which is the failure this whole file
  # is written to avoid, so it has to be fatal rather than vacuously green.
  hostNoPe = pkgs.runCommand "hostlibs-host-no-pe" { } ''
    mkdir -p $out/bin
    echo "no PE in this host bundle's bin/" > $out/bin/readme.txt
  '';

  bundleOf = args: mkBundle ({ warnOnBinaryData = true; } // args);

  # `find | sort` of the bundle's PE files, relative -- the whole assertion is
  # about WHICH files are there, so compare the set rather than a count.
  # Deliberately not `-type f`: a DIRECTORY named like a DLL is part of what
  # some subjects are asserting about.
  peSet = b: "cd ${b} && find . -name '*.dll' -o -name '*.exe' | LC_ALL=C sort | tr '\\n' ' '";

  expect = name: bundle: want: pkgs.runCommand "check-${name}" { } ''
    got="$(${peSet bundle})"
    want="${want}"
    if [ "$got" != "$want" ]; then
      echo "FAIL ${name}: the bundle's PE set is" >&2
      echo "    $got" >&2
      echo "  and it should be" >&2
      echo "    $want" >&2
      exit 1
    fi
    echo "ok ${name}: $got"
    touch $out
  '';
in
{
  # ---- must BUILD, and must contain exactly the payload -------------------

  # The strip, on the shape it exists for. Three linked-in host DLLs in, one
  # payload file out. Without the Phase 6 half this build fails instead.
  moduleStripped = expect "module-stripped"
    (bundleOf { drv = moduleLinked; name = "hostlibs-module-stripped"; hostLibs = hostDlls; })
    "./lib/demo_plugin.dll ";

  # Same, with the claim CHECKED against the host's own bundle rather than
  # taken on trust.
  moduleStrippedVerified = expect "module-stripped-verified"
    (bundleOf {
      drv = moduleLinked; name = "hostlibs-module-stripped-v";
      hostLibs = hostDlls; hostBundle = hostGood;
    })
    "./lib/demo_plugin.dll ";

  # The import-level half on its own: nothing to strip (the DLLs were never
  # staged) and nothing in the closure to resolve them from either, because a
  # PE embeds no store paths. The ONLY thing that can make this build is Phase
  # 6 accepting a host-claimed name as resolved. Without `hostLibs` the same
  # derivation fails with "1 DLL import(s) could not be resolved" -- which is
  # what `moduleUnclaimed` below asserts.
  moduleClaimedOnly = expect "module-claimed-only"
    (bundleOf {
      drv = moduleBare; name = "hostlibs-module-claimed";
      hostLibs = hostDlls; hostBundle = hostGood;
    })
    "./lib/demo_plugin.dll ";

  # A PE import table spells one DLL two ways inside a single bundle
  # (KERNEL32.DLL and KERNEL32.dll both occur in this toolchain's own output),
  # so the PE match folds case on BOTH sides -- pattern included. A caller
  # writing the wrong case must not silently get an unstripped package.
  moduleStrippedMixedCase = expect "module-stripped-mixed-case"
    (bundleOf {
      drv = moduleLinked; name = "hostlibs-module-case";
      hostLibs = [ "LIBSTDC++-*.DLL" "LibGCC_S_*.Dll" "LIBMCFGTHREAD-*.DLL" ];
      hostBundle = hostGood;
    })
    "./lib/demo_plugin.dll ";

  # COPIED, not linked. Identical outcome to `moduleStripped`, and that is the
  # assertion: how a file got into the derivation's output is not something this
  # bundler reasons about. The provenance rule this replaces kept all three of
  # these and reported a successful strip of nothing.
  copiesStrippedToo = expect "copies-stripped-too"
    (bundleOf {
      drv = moduleCopied; name = "hostlibs-copies";
      hostLibs = hostDlls; hostBundle = hostGood;
    })
    "./lib/demo_plugin.dll ";

  # A bin/ with no executable in it: the strip empties it, and Phase 6 has to
  # tell "this build removed bin/x.dll" from "Phase 1 lost bin/x.dll". Before
  # that arm existed this build failed with three "in the source derivation but
  # not in the bundle" errors -- the strip and the verifier disagreeing about
  # one decision.
  moduleBinStripped = expect "module-bin-stripped"
    (bundleOf {
      drv = moduleBinDlls; name = "hostlibs-module-bin";
      hostLibs = hostDlls; hostBundle = hostGood;
    })
    "./lib/demo_plugin.dll ";

  # ---- what the strip may NOT remove --------------------------------------

  # `extraDirs` is an explicit "carry this". The linked-in copies in lib/ go;
  # the caller's own copy under share/assets stays. Measured before the fix:
  # "- share/assets/libstdc++-6.dll (host-provided)", the directory shipped
  # empty, rc=0.
  extraDirsKept = expect "extra-dirs-kept"
    (bundleOf {
      drv = moduleWithAssets; name = "hostlibs-assets";
      hostLibs = hostDlls; hostBundle = hostGood;
      extraDirs = [ "share/assets" ];
    })
    "./lib/demo_plugin.dll ./share/assets/libstdc++-6.dll ";

  # ...and the strip is not the only thing that has to respect that. The sweep
  # WRITES: its beside-the-importer rule mirrors a dependency into bin/, and it
  # used to do that before asking whether hostLibs claimed the name, so a
  # host-matched DLL travelled out of the extraDirs entry and into bin/. The
  # assertion is therefore about bin/ as much as about share/assets: the three
  # host DLLs stay where the caller put them and appear NOWHERE else.
  #
  # Both `./bin/demo_plugin.dll` and `./share/assets/asset_plugin.dll` are in the
  # expected set for a reason -- the first is what makes bin/ a real destination
  # to mirror into, the second is the importer that triggers the mirror. Drop
  # either and the subject stops reaching the arm it is written for.
  extraDirsNotMirrored = expect "extra-dirs-not-mirrored"
    (bundleOf {
      drv = moduleAssetsImporter; name = "hostlibs-assets-importer";
      hostLibs = hostDlls; hostBundle = hostGood;
      extraDirs = [ "share/assets" ];
    })
    ("./bin/demo_plugin.dll ./lib/demo_plugin.dll "
     + "./share/assets/asset_plugin.dll ./share/assets/libgcc_s_seh-1.dll "
     + "./share/assets/libmcfgthread-2.dll ./share/assets/libstdc++-6.dll ");

  # THE BUNDLER-INJECTED PATTERN. `bundlers.<sys>.qtPlugin` appends `Qt*` to
  # hostLibs itself -- a list the caller never sees -- and on the PE path that
  # would DELETE, case-folded, matching a Qt plugin package's own output.
  # Measured on the real Windows Qt bundle while it did: 816 PEs in, 796 out,
  # exit 0. flake.nix now appends it only on a non-Windows target, so this
  # bundle keeps its own Qt6Core.dll and everything else it was given.
  qtPluginBundlerKeepsPayload = expect "qt-plugin-bundler-keeps-payload"
    (qtPluginBundler qtNamedModule)
    ("./lib/Qt6Core.dll ./lib/demo_plugin.dll ./lib/libgcc_s_seh-1.dll "
     + "./lib/libmcfgthread-2.dll ./lib/libstdc++-6.dll ");

  # The other half of the same rule, and the reason the gate is about WHO
  # declared the pattern rather than about the pattern: the same file name, the
  # same bundle, a CALLER-written `Qt*.dll` -- and it goes, because that is what
  # the caller asked for. hostBundle then has to ship it, which is what makes
  # the request checkable rather than merely obeyed.
  callerQtStripsOwnQt = expect "caller-qt-strips-own-qt"
    (bundleOf {
      drv = qtNamedModule; name = "hostlibs-caller-qt";
      hostLibs = hostDlls ++ [ "Qt*.dll" ]; hostBundle = hostWithQt;
    })
    "./lib/demo_plugin.dll ";

  # The `pe_is_host_lib "$qt_lib_name"` arm in Qt detection, reached the one way
  # it still can be: a DIRECTORY named like a Qt DLL, which the strip cannot
  # remove (`find -type f`) and detection counts (`[ -e ]`). It answers
  # "host-provided", so Phase 2b skips Qt staging and this builds. The control
  # is `qtDirNotHostProvided` below, which is the same input without `Qt*` and
  # dies demanding a Qt plugin directory.
  qtDirHostProvided = expect "qt-dir-host-provided"
    (bundleOf {
      drv = qtDirModule; name = "hostlibs-qt-dir";
      hostLibs = hostDlls ++ [ "Qt*.dll" ]; hostBundle = hostGood;
    })
    "./bin/Qt6Core.dll ./lib/demo_plugin.dll ";

  # ---- must FAIL, each on a different arm --------------------------------
  # Kept out of `checks` for the same reason extra-dirs-dirty is: `nix flake
  # check` builds checks and would call the repo broken. smoke.sh builds each
  # of these expecting the failure, and asserts what the failure says.

  # A claim the host does not keep. The DLL is in the host bundle, just not in
  # the directory Windows searches -- so a whole-tree check would pass this.
  hostClaimBroken = bundleOf {
    drv = moduleLinked; name = "hostlibs-fail-claim";
    hostLibs = hostDlls; hostBundle = hostMisplaced;
  };

  # A hostBundle that cannot be a host bundle. Verifying against it would
  # accept everything.
  hostBundleVacuous = bundleOf {
    drv = moduleLinked; name = "hostlibs-fail-vacuous";
    hostLibs = hostDlls; hostBundle = hostNoPe;
  };

  # hostBundle with an EMPTY hostLibs. It was accepted and then never
  # consulted: pe_strip_host_libs returned at its "no hostLibs declared" arm
  # before pe_host_index ran, so nothing was indexed, nothing was checked and
  # nothing was printed. A check that can only report success about nothing is
  # the reading this argument exists to make impossible.
  hostBundleWithoutHostLibs = bundleOf {
    drv = moduleLinked; name = "hostlibs-fail-nolibs"; hostBundle = hostGood;
  };

  # The same, with a hostBundle that is obvious garbage -- which is the point:
  # with an empty hostLibs, NOTHING about it was looked at. This one has to
  # fail on the vacuous-host arm rather than the empty-list arm, which is why
  # pe_host_index is called before that refusal and not after.
  hostBundleGarbageIgnored = bundleOf {
    drv = moduleLinked; name = "hostlibs-fail-nolibs-garbage"; hostBundle = hostNoPe;
  };

  # hostBundle on a target that is not Windows: refused at EVALUATION time by
  # mkBundle.nix, since Nix already knows the answer. `pkgs.hello` is an
  # ordinary native derivation.
  hostBundleOnUnix = bundleOf {
    drv = pkgs.hello; name = "hostlibs-fail-unix"; hostLibs = [ "libz.so*" ];
    hostBundle = hostGood;
  };

  # hostBundle on a target Nix cannot read. mkBundle's throwIf deliberately
  # fires on `isWindowsStr == "0"` only, leaving "unknown" to bundle.sh, which
  # resolves it to Unix in Phase 1c and refuses there -- an arm nothing reached
  # until this subject, because every other stdenv-less shape also has no
  # reason to pass a hostBundle. `removeAttrs` is how a real Windows tree with
  # no stdenv is reproduced: a `builtins.storePath` cannot be written in a pure
  # flake, and everything else about the derivation is unchanged.
  hostBundleOnUnknownTarget = bundleOf {
    drv = builtins.removeAttrs moduleLinked [ "stdenv" ];
    name = "hostlibs-fail-unknown"; hostLibs = hostDlls; hostBundle = hostGood;
  };

  # hostBundle that is not a directory at all. `pe_host_index` refuses it, and
  # nothing reached that arm either: every other subject passes a runCommand
  # output. A `.cpp` in the store is a store path a caller could plausibly
  # paste in.
  hostBundleNotADirectory = bundleOf {
    drv = moduleLinked; name = "hostlibs-fail-notdir";
    hostLibs = hostDlls; hostBundle = pluginSrc;
  };

  # The floor. `*.dll` is a list the caller is ALLOWED to write -- a declared
  # pattern deletes -- but a bundle with no PE left in it cannot be what anyone
  # meant, and it is the one case that needs no judgement about which file was
  # the payload. Under the provenance rule this same subject built green.
  stripEverything = bundleOf {
    drv = moduleLinked; name = "hostlibs-fail-stripall"; hostLibs = [ "*.dll" ];
  };

  # The control for `qtDirHostProvided`: identical input, no `Qt*` in hostLibs.
  # Qt is then detected and NOT host-provided, so Phase 2b goes looking for a Qt
  # plugin directory in a closure that has none and the build dies. That
  # difference is the demonstration that the arm is reached and changes the
  # verdict.
  qtDirNotHostProvided = bundleOf {
    drv = qtDirModule; name = "hostlibs-fail-qt-dir";
    hostLibs = hostDlls; hostBundle = hostGood;
  };

  # The app shape. Windows resolves a host-provided DLL through the LOADING
  # PROCESS's own directory; when the bundle has an executable of its own that
  # directory is the bundle's bin/, where the stripped DLLs no longer are.
  # Measured: such a bundle dies 0xC0000135 before main() with no output, and
  # runs only with the host's bin/ on PATH. It used to build green here.
  appShapeRefused = bundleOf {
    drv = appLinked; name = "hostlibs-fail-app";
    hostLibs = hostDlls; hostBundle = hostGood;
  };

  # The same refusal, on a bundle with no application directory at all: the .exe
  # is in lib/. The scan behind the refusal used to look only inside bin/, one
  # level deep, so this built green while README.md and mkBundle.nix both
  # described it as refused. It is the same failure as `appShapeRefused` -- the
  # loading process is this bundle's own .exe and the directory Windows searches
  # is the directory that .exe sits in, which is the directory the strip just
  # emptied.
  appInLibRefused = bundleOf {
    drv = appInLib; name = "hostlibs-fail-app-in-lib";
    hostLibs = hostDlls; hostBundle = hostGood;
  };

  # The control for `moduleClaimedOnly`: identical input, no hostLibs. If this
  # ever starts building, the subject above has stopped proving anything.
  moduleUnclaimed = bundleOf { drv = moduleBare; name = "hostlibs-fail-unclaimed"; };
}
