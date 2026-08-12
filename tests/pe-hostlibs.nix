# The Windows/PE `hostLibs` contract, as buildable subjects.
#
# `hostLibs` names libraries the RUNTIME HOST already ships, so the bundle must
# not carry them. It was accepted by mkBundle.nix and applied on the Unix path
# from the start; on the PE path it reached the derivation as HOST_LIBS and
# then changed nothing, which for a Logos module meant ~36 MB of Qt, OpenSSL
# and C++ runtime (Qt6Core.dll alone is 15 MB) inside every package.
#
# Two halves, and NEITHER works alone. Strip without teaching Phase 6 and the
# import verifier fails on the very DLLs that were just removed; teach Phase 6
# without stripping and the package still ships them. So the subjects here
# assert both: what the tree contains AFTER the strip, and that the build got
# past the verifier to produce it.
#
# The third half is `hostBundle`, which is what makes the list checkable rather
# than declared. Every hostLibs entry is a promise about another repo's output,
# and a broken promise is silent on Windows: LoadLibrary fails with
# ERROR_MOD_NOT_FOUND (126) and Qt reports only "The specified module could not
# be found", naming the PLUGIN rather than the missing DLL.
#
# Why these are here and not in smoke.sh: smoke.sh drives `nix bundle
# --bundler . nixpkgs#hello`, which cannot express hostLibs, hostBundle, a
# cross target, or a module-shaped output at all.
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

  # `dontFixup`, so the fixture is exactly what this file says it is: the
  # mingw stdenv's own win-dll-link hook would otherwise stage DLLs into bin/
  # on its own schedule and the subjects would be asserting about its output
  # rather than about the bundler's.

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
  # i.e. with the whole import closure already staged beside the plugin. This
  # is what the workspace's module derivations really produce, and it is the
  # one the strip has to shrink -- import-level skipping alone would leave
  # every one of these files in place.
  moduleStaged = mingw.stdenv.mkDerivation {
    name = "hostlibs-module-staged";
    dontUnpack = true;
    dontFixup = true;
    buildPhase = "$CXX -shared -o demo_plugin.dll ${pluginSrc}";
    installPhase = ''
      mkdir -p $out/lib && cp demo_plugin.dll $out/lib/
      cp ${dllDir}/libstdc++-6.dll ${dllDir}/libgcc_s_seh-1.dll ${mcfgDll} $out/lib/
      chmod +w $out/lib/*.dll
    '';
  };

  # SHAPE 2: an application. Has a bin/, which is a different code path in
  # three places -- the sweep stages into it, Phase 1c counts it, and Phase 6
  # asserts every source bin/ entry survived. That last one FAILS the build on
  # a stripped app unless it is taught the same rule as the strip.
  appStaged = mingw.stdenv.mkDerivation {
    name = "hostlibs-app-staged";
    dontUnpack = true;
    dontFixup = true;
    buildPhase = "$CXX -o demo_app.exe ${appSrc}";
    installPhase = ''
      mkdir -p $out/bin && cp demo_app.exe $out/bin/
      cp ${dllDir}/libstdc++-6.dll ${dllDir}/libgcc_s_seh-1.dll ${mcfgDll} $out/bin/
      chmod +w $out/bin/*.dll
    '';
  };

  # The host's own bundle: the tree whose application directory the host
  # process runs from. `bin/`, because that is the directory Windows searches
  # for the loading process.
  hostGood = pkgs.runCommand "hostlibs-host-good" { } ''
    mkdir -p $out/bin
    cp ${dllDir}/libstdc++-6.dll ${dllDir}/libgcc_s_seh-1.dll ${mcfgDll} $out/bin/
    cp ${appStaged}/bin/demo_app.exe $out/bin/host.exe
  '';

  # The same host with libgcc_s_seh-1.dll in lib/ instead of bin/. Not a
  # contrived shape: "it is in the host bundle somewhere" is precisely the
  # mistake, and it is invisible to any check that greps the whole tree.
  hostMisplaced = pkgs.runCommand "hostlibs-host-misplaced" { } ''
    mkdir -p $out/bin $out/lib
    cp ${dllDir}/libstdc++-6.dll ${mcfgDll} $out/bin/
    cp ${appStaged}/bin/demo_app.exe $out/bin/host.exe
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

  # The strip, on the shape it exists for. Three host DLLs in, one payload
  # file out. Without the Phase 6 half this build fails instead.
  moduleStripped = expect "module-stripped"
    (bundleOf { drv = moduleStaged; name = "hostlibs-module-stripped"; hostLibs = hostDlls; })
    "./lib/demo_plugin.dll ";

  # Same, with the claim CHECKED against the host's own bundle rather than
  # taken on trust.
  moduleStrippedVerified = expect "module-stripped-verified"
    (bundleOf {
      drv = moduleStaged; name = "hostlibs-module-stripped-v";
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
  # entry is still here" check has to accept as deliberate.
  appStripped = expect "app-stripped"
    (bundleOf {
      drv = appStaged; name = "hostlibs-app-stripped";
      hostLibs = hostDlls; hostBundle = hostGood;
    })
    "./bin/demo_app.exe ";

  # A PE import table spells one DLL two ways inside a single bundle
  # (KERNEL32.DLL and KERNEL32.dll both occur in this toolchain's own output),
  # so the PE match folds case on BOTH sides -- pattern included. A caller
  # writing the wrong case must not silently get an unstripped package.
  moduleStrippedMixedCase = expect "module-stripped-mixed-case"
    (bundleOf {
      drv = moduleStaged; name = "hostlibs-module-case";
      hostLibs = [ "LIBSTDC++-*.DLL" "LibGCC_S_*.Dll" "LIBMCFGTHREAD-*.DLL" ];
      hostBundle = hostGood;
    })
    "./lib/demo_plugin.dll ";

  # ---- must FAIL, each on a different arm --------------------------------
  # Kept out of `checks` for the same reason extra-dirs-dirty is: `nix flake
  # check` builds checks and would call the repo broken.

  # A claim the host does not keep. The DLL is in the host bundle, just not in
  # the directory Windows searches -- so a whole-tree check would pass this.
  hostClaimBroken = bundleOf {
    drv = moduleStaged; name = "hostlibs-fail-claim";
    hostLibs = hostDlls; hostBundle = hostMisplaced;
  };

  # A hostBundle that cannot be a host bundle. Verifying against it would
  # accept everything.
  hostBundleVacuous = bundleOf {
    drv = moduleStaged; name = "hostlibs-fail-vacuous";
    hostLibs = hostDlls; hostBundle = hostNoPe;
  };

  # An over-broad pattern that eats the package's own payload. `*.dll` is the
  # one that has actually been written, and the shape it produces -- a bundle
  # with nothing in it -- makes every check downstream pass by measuring
  # nothing.
  stripEverything = bundleOf {
    drv = moduleStaged; name = "hostlibs-fail-stripall"; hostLibs = [ "*.dll" ];
  };

  # The same over-broad pattern on the single-file module shape, where "every
  # PE was removed" and "there was only ever one PE" are the same tree.
  stripEverythingBare = bundleOf {
    drv = moduleBare; name = "hostlibs-fail-stripall-bare"; hostLibs = [ "*.dll" ];
  };

  # The control for `moduleClaimedOnly`: identical input, no hostLibs. If this
  # ever starts building, the subject above has stopped proving anything.
  moduleUnclaimed = bundleOf { drv = moduleBare; name = "hostlibs-fail-unclaimed"; };
}
