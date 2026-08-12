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
# And one rule that BOUNDS the strip, because deleting is not the same
# operation as declining to add. On ELF and Mach-O `hostLibs` only ever filters
# what `trace_deps` copies IN; on Windows the import closure has already been
# staged into the derivation's own output by nixpkgs' win-dll-link.sh before
# the bundler runs, so the PE path has to delete. The rule is:
#
#   the strip may only remove a file that came along WITH the package — one
#   the bundler staged, or one win-dll-link.sh linked in from another store
#   path — never a file the derivation's own build produced.
#
# That rule is why the fixtures below distinguish LINKED runtime DLLs (the real
# win-dll-link shape, `ln -sr` into another store path) from COPIED ones. Both
# shapes exist in the wild and the bundler must treat them differently: the
# first is a dependency travelling with the package, the second is the
# package's own output. Two measured defects — `bundlers.qtPlugin` deleting
# `qtquick2plugin.dll` because it appends `Qt*` to hostLibs itself, and the
# strip emptying an `extraDirs` entry — close on that one rule, and neither
# closes on a rule about pattern syntax.
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
{ pkgs, mkBundle }:

let
  inherit (pkgs) lib;
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
  # about the bundler's. The hook's SHAPE is reproduced by hand where it
  # matters — `ln -s` into another store path, which is what `ln -sr` produces
  # once Nix has resolved it — because that shape is exactly what the payload
  # rule reads.

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

  # SHAPE 1c: the same names, but COPIED into the derivation's own output
  # rather than linked. Byte-for-byte the same DLLs; the difference is that
  # this derivation produced them, so they are its payload and the strip may
  # not touch them however the patterns read.
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
  # EMPTY, rc=0. Not fixable by exempting extraDirs wholesale either, since the
  # sweep legitimately stages a dependency into an extraDir when the importer
  # lives there; only provenance separates the two.
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

  # SHAPE 1e: a derivation with NO output of its own -- every file in it is a
  # link to another store path. By the payload rule it has no payload, so
  # `hostLibs` governs its whole tree and an over-broad list can still empty
  # it. That is the one shape the floor in pe_strip_host_libs still guards, and
  # this is what makes the floor demonstrable rather than asserted.
  moduleAllLinked = mingw.stdenv.mkDerivation {
    name = "hostlibs-module-all-linked";
    dontUnpack = true;
    dontBuild = true;
    dontFixup = true;
    installPhase = ''
      mkdir -p $out/lib
      ln -s ${dllDir}/libstdc++-6.dll ${dllDir}/libgcc_s_seh-1.dll ${mcfgDll} $out/lib/
    '';
  };

  # SHAPE 2: an application. Has a bin/, which is a different code path in
  # three places -- the sweep stages into it, Phase 1c counts it, and Phase 6
  # asserts every source bin/ entry survived. That last one FAILS the build on
  # a stripped app unless it is taught the same rule as the strip.
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

  # A plain copy of the app, for building the host bundle out of.
  appPlain = mingw.stdenv.mkDerivation {
    name = "hostlibs-app-plain";
    dontUnpack = true;
    dontFixup = true;
    buildPhase = "$CXX -o demo_app.exe ${appSrc}";
    installPhase = "mkdir -p $out/bin && cp demo_app.exe $out/bin/";
  };

  # SHAPE 3: an application whose OWN BUILD produces a PE named like a Qt
  # library. Contrived-looking and not contrived: it is the shape of every Qt
  # module package, and it is the only way to reach the `pe_is_host_lib
  # "$qt_lib_name"` arm in the Qt-detection block with a host-claimed name --
  # which an earlier comment in bundle.sh asserted was unreachable.
  qtNamedApp = mingw.stdenv.mkDerivation {
    name = "hostlibs-qt-named-app";
    dontUnpack = true;
    dontFixup = true;
    buildPhase = ''
      $CXX -o demo_app.exe ${appSrc}
      $CXX -shared -o Qt6Core.dll ${pluginSrc}
    '';
    installPhase = ''
      mkdir -p $out/bin && cp demo_app.exe Qt6Core.dll $out/bin/
      ln -s ${dllDir}/libstdc++-6.dll ${dllDir}/libgcc_s_seh-1.dll ${mcfgDll} $out/bin/
    '';
  };

  # The host's own bundle: the tree whose application directory the host
  # process runs from. `bin/`, because that is the directory Windows searches
  # for the loading process.
  hostGood = pkgs.runCommand "hostlibs-host-good" { } ''
    mkdir -p $out/bin
    cp ${dllDir}/libstdc++-6.dll ${dllDir}/libgcc_s_seh-1.dll ${mcfgDll} $out/bin/
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

  # The app shape. bin/ loses two DLLs, which Phase 6's "every source bin/
  # entry is still here" check has to accept as deliberate -- and it accepts
  # them by PATH, from the set this build actually removed, not by re-testing
  # the name against hostLibs.
  appStripped = expect "app-stripped"
    (bundleOf {
      drv = appLinked; name = "hostlibs-app-stripped";
      hostLibs = hostDlls; hostBundle = hostGood;
    })
    "./bin/demo_app.exe ";

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

  # ---- the payload rule ---------------------------------------------------

  # THE `*.dll` SUBJECT. Before the payload rule this pattern removed every PE
  # in the bundle and the build died on the floor; the real defect it stands
  # for is the same pattern removing SOME payload and exiting 0. Now the
  # patterns cannot reach the derivation's own output at all, so the widest
  # possible list still ships the package.
  payloadSurvivesWildcard = expect "payload-survives-wildcard"
    (bundleOf {
      drv = moduleLinked; name = "hostlibs-payload-wildcard"; hostLibs = [ "*.dll" ];
    })
    "./lib/demo_plugin.dll ";

  # The same names, copied rather than linked: this derivation produced them,
  # so all four files stay. hostBundle is given, which before the fix would
  # have failed the build -- the import arms claimed every matching name from
  # the host whether or not the bundle already satisfied it.
  payloadCopiesKept = expect "payload-copies-kept"
    (bundleOf {
      drv = moduleCopied; name = "hostlibs-payload-copies";
      hostLibs = hostDlls; hostBundle = hostGood;
    })
    "./lib/demo_plugin.dll ./lib/libgcc_s_seh-1.dll ./lib/libmcfgthread-2.dll ./lib/libstdc++-6.dll ";

  # `extraDirs` is an explicit "carry this". The linked-in copies in lib/ go;
  # the caller's own copy under share/assets stays. Measured before the fix:
  # "- share/assets/libstdc++-6.dll (host-provided)", the directory shipped
  # empty, rc=0.
  extraDirsPayloadKept = expect "extra-dirs-payload-kept"
    (bundleOf {
      drv = moduleWithAssets; name = "hostlibs-assets";
      hostLibs = hostDlls; hostBundle = hostGood;
      extraDirs = [ "share/assets" ];
    })
    "./lib/demo_plugin.dll ./share/assets/libstdc++-6.dll ";

  # `bundlers.qtPlugin` appends `Qt*` to hostLibs ITSELF, and the PE match
  # folds case, so it reads `qt*` and matches a Qt plugin's own
  # `qtquick2plugin.dll`. Here the derivation's own Qt6Core.dll survives a
  # `Qt*.dll` list while the linked-in runtime DLLs are stripped -- and the
  # build only gets that far because the survivor makes the Qt-detection arm
  # answer "host-provided", which is what `qtPayloadNotHostProvided` below
  # controls for.
  qtPayloadKept = expect "qt-payload-kept"
    (bundleOf {
      drv = qtNamedApp; name = "hostlibs-qt-payload";
      hostLibs = hostDlls ++ [ "Qt*.dll" ]; hostBundle = hostGood;
    })
    "./bin/Qt6Core.dll ./bin/demo_app.exe ";

  # The same subject with NO hostBundle, which is the defect exactly as it
  # shipped: `bundlers.qtPlugin` appends `Qt*` and passes no host bundle, so
  # nothing adjudicated the claim and the deletion was silent. Measured against
  # the pre-fix tree: exit 0 with a PE set of `./bin/demo_app.exe ` — the
  # bundler had quietly removed the file it was packaging.
  qtPayloadKeptUnverified = expect "qt-payload-kept-unverified"
    (bundleOf {
      drv = qtNamedApp; name = "hostlibs-qt-payload-u";
      hostLibs = hostDlls ++ [ "Qt*" ];
    })
    "./bin/Qt6Core.dll ./bin/demo_app.exe ";

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

  # The floor, on the one shape that can still reach it: a derivation that
  # produced no file of its own, so the payload rule has nothing to protect.
  stripEverythingLinked = bundleOf {
    drv = moduleAllLinked; name = "hostlibs-fail-stripall"; hostLibs = [ "*.dll" ];
  };

  # The control for `qtPayloadKept`: identical input, no `Qt*` in hostLibs. Qt
  # is then detected and NOT host-provided, so Phase 2b goes looking for a Qt
  # plugin directory in a closure that has none and the build dies. That
  # difference is the demonstration that the `pe_is_host_lib "$qt_lib_name"`
  # arm is reached and changes the verdict -- bundle.sh used to carry a comment
  # claiming it could not be.
  qtPayloadNotHostProvided = bundleOf {
    drv = qtNamedApp; name = "hostlibs-fail-qt-not-host";
    hostLibs = hostDlls; hostBundle = hostGood;
  };

  # The control for `moduleClaimedOnly`: identical input, no hostLibs. If this
  # ever starts building, the subject above has stopped proving anything.
  moduleUnclaimed = bundleOf { drv = moduleBare; name = "hostlibs-fail-unclaimed"; };
}
