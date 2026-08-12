{
  description = "Bundle Nix derivations into self-contained directories";

  inputs = {
    logos-nix.url = "github:logos-co/logos-nix";
    nixpkgs.follows = "logos-nix/nixpkgs";
  };

  outputs = { self, nixpkgs, logos-nix }:
    let
      systems = [ "aarch64-darwin" "x86_64-darwin" "aarch64-linux" "x86_64-linux" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f {
        inherit system;
        pkgs = nixpkgs.legacyPackages.${system};
      });
    in
    {
      lib = forAllSystems ({ pkgs, ... }: {
        mkBundle = import ./mkBundle.nix { inherit pkgs; };
      });

      # `nix flake check` builds this; so does tests/smoke.sh, which is what
      # CI runs. See tests/extra-dirs.nix for why the extraDirs contract cannot
      # be expressed through smoke.sh's `nix bundle --bundler . nixpkgs#hello`
      # calls at all.
      checks = forAllSystems ({ pkgs, system, ... }:
        let peHostLibs = import ./tests/pe-hostlibs.nix {
              inherit pkgs;
              mkBundle = import ./mkBundle.nix { inherit pkgs; };
            };
        in {
          extra-dirs-nested =
            (import ./tests/extra-dirs.nix {
              inherit pkgs;
              mkBundle = import ./mkBundle.nix { inherit pkgs; };
            }).nested;
        }
        # x86_64-linux only. Every subject in there is a `pkgsCross.mingwW64`
        # build: on aarch64-linux the mingw toolchain is not substitutable and
        # `nix flake check` would spend hours compiling GCC, and on Darwin the
        # cross stdenv does not evaluate at all. Restricting the ATTRIBUTE
        # rather than making the subjects no-ops keeps a green check on the
        # other systems from meaning "the PE contract passed" when it was never
        # built.
        // nixpkgs.lib.optionalAttrs (system == "x86_64-linux") {
          pe-hostlibs-module          = peHostLibs.moduleStripped;
          pe-hostlibs-module-verified = peHostLibs.moduleStrippedVerified;
          pe-hostlibs-claimed-only    = peHostLibs.moduleClaimedOnly;
          pe-hostlibs-app             = peHostLibs.appStripped;
          pe-hostlibs-mixed-case      = peHostLibs.moduleStrippedMixedCase;
          # The payload rule: what the strip may NOT remove.
          pe-hostlibs-payload-wildcard = peHostLibs.payloadSurvivesWildcard;
          pe-hostlibs-payload-copies   = peHostLibs.payloadCopiesKept;
          pe-hostlibs-payload-extradirs = peHostLibs.extraDirsPayloadKept;
          pe-hostlibs-payload-qt        = peHostLibs.qtPayloadKept;
          pe-hostlibs-payload-qt-unverified = peHostLibs.qtPayloadKeptUnverified;
        });

      # Subjects that MUST fail to build. Kept out of `checks` on purpose:
      # `nix flake check` would build them and call the repo broken. smoke.sh
      # builds extra-dirs-dirty expecting the failure, and asserts what the
      # failure says; the pe-hostlibs entries are built the same way by hand
      # (`nix build .#tests.x86_64-linux.<name>` — each must exit 1, and each
      # exits 1 on a DIFFERENT arm, so the message is the assertion).
      tests = forAllSystems ({ pkgs, system, ... }:
        let peHostLibs = import ./tests/pe-hostlibs.nix {
              inherit pkgs;
              mkBundle = import ./mkBundle.nix { inherit pkgs; };
            };
        in {
          extra-dirs-dirty =
            (import ./tests/extra-dirs.nix {
              inherit pkgs;
              mkBundle = import ./mkBundle.nix { inherit pkgs; };
            }).dirty;
        }
        // nixpkgs.lib.optionalAttrs (system == "x86_64-linux") {
          pe-hostlibs-claim-broken     = peHostLibs.hostClaimBroken;
          pe-hostlibs-host-vacuous     = peHostLibs.hostBundleVacuous;
          pe-hostlibs-host-no-libs     = peHostLibs.hostBundleWithoutHostLibs;
          pe-hostlibs-host-no-libs-garbage = peHostLibs.hostBundleGarbageIgnored;
          pe-hostlibs-host-on-unix     = peHostLibs.hostBundleOnUnix;
          pe-hostlibs-strip-everything = peHostLibs.stripEverythingLinked;
          pe-hostlibs-qt-not-host      = peHostLibs.qtPayloadNotHostProvided;
          pe-hostlibs-unclaimed        = peHostLibs.moduleUnclaimed;
        });

      bundlers = forAllSystems ({ pkgs, ... }:
        let
          mkBundle = import ./mkBundle.nix { inherit pkgs; };
          bundle = { warnOnBinaryData ? true }: drv:
            mkBundle {
              inherit drv warnOnBinaryData;
              name = drv.pname or drv.name or "bundle";
              extraDirs = drv.extraDirs or [];
              extraClosurePaths = drv.extraClosurePaths or [];
              hostBundle = drv.hostBundle or null;
              hostLibs = drv.hostLibs or [];
            };
        in {
          default = bundle { warnOnBinaryData = false; };
          permissive = bundle { warnOnBinaryData = true; };
          qtApp = drv:
            mkBundle {
              inherit drv;
              name = drv.pname or drv.name or "bundle";
              extraDirs = drv.extraDirs or [];
              extraClosurePaths = drv.extraClosurePaths or [];
              hostBundle = drv.hostBundle or null;
              hostLibs = drv.hostLibs or [];
              warnOnBinaryData = true;
            };
          # A Qt program that never puts anything on screen — a headless CLI or
          # daemon. Same bundling as qtApp, but its bin/ entries stay plain
          # binaries: with no GUI there is no platform plugin, so nothing needs
          # XKB_CONFIG_ROOT or the portal theme, and there is no reason to pay
          # for a launcher and a hidden companion ELF.
          #
          # Use qtApp instead for anything that renders, INCLUDING a host
          # process that only loads UI plugins at runtime — see `guiApp` in
          # mkBundle.nix for why that case cannot be detected.
          qtCliApp = drv:
            mkBundle {
              inherit drv;
              name = drv.pname or drv.name or "bundle";
              extraDirs = drv.extraDirs or [];
              extraClosurePaths = drv.extraClosurePaths or [];
              hostBundle = drv.hostBundle or null;
              hostLibs = drv.hostLibs or [];
              warnOnBinaryData = true;
              guiApp = false;
            };
          # A Qt plugin is loaded INTO a Qt host, so the Qt runtime is the
          # host's, and this bundler says so on the caller's behalf.
          #
          # Note what that appended `Qt*` is: a pattern the BUNDLER writes,
          # which the caller never sees and cannot review. On the PE path the
          # match folds case on both sides, so it reads `qt*` and matches the
          # plugin's own `qtquick2plugin.dll` as readily as `Qt6Core.dll` —
          # measured on the real Windows Qt bundle, before the payload rule
          # existed, as 816 PE files in and 796 out with exit 0. It is only
          # sound to inject a pattern here because `pe_strip_host_libs` can no
          # longer remove anything the bundled derivation's own build produced.
          # Do not widen this without re-reading that rule.
          qtPlugin = drv:
            mkBundle {
              inherit drv;
              name = drv.pname or drv.name or "bundle";
              extraDirs = drv.extraDirs or [];
              extraClosurePaths = drv.extraClosurePaths or [];
              hostBundle = drv.hostBundle or null;
              hostLibs = (drv.hostLibs or []) ++ [ "Qt*" ];
              warnOnBinaryData = true;
            };
        });
    };
}
