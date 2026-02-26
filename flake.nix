{
  description = "Bundle Nix derivations into self-contained directories";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      systems = [ "aarch64-darwin" "x86_64-darwin" "aarch64-linux" "x86_64-linux" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f {
        inherit system;
        pkgs = nixpkgs.legacyPackages.${system};
      });
    in
    {
      # Overlay that reverts Nix-specific patches from libraries that hardcode
      # /nix/store paths, making them portable for bundling.  Consumers should
      # apply this overlay to their nixpkgs instance *before* building the
      # derivation that will be bundled.
      overlays.portable = final: prev: {
        libproxy = prev.libproxy.overrideAttrs (old: {
          # Nixpkgs patches libproxy with two patches:
          #   skip-gsettings-detection.patch — sets available=TRUE unconditionally
          #     (needed because detection fails in the Nix sandbox)
          #   hardcode-gsettings.patch — replaces g_settings_new() with
          #     g_settings_schema_source_new_from_directory("/nix/store/...")
          #
          # We keep the detection skip (build sandbox needs it) but remove the
          # hardcode patch so libproxy uses g_settings_new() at runtime, which
          # respects XDG_DATA_DIRS / GSETTINGS_SCHEMA_DIR for portable bundles.
          patches = builtins.filter (p:
            builtins.baseNameOf (builtins.toString p) != "hardcode-gsettings.patch"
          ) (old.patches or []);
          # The GNOME config test fails in the sandbox (no schemas installed).
          # The skip-detection patch keeps the code path alive; we just can't
          # test it without schemas present during the build.
          mesonFlags = (old.mesonFlags or []) ++ [ "-Dtests=false" ];
        });
      };

      lib = forAllSystems ({ pkgs, ... }: {
        mkBundle = import ./mkBundle.nix { inherit pkgs; };
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
              hostLibs = drv.hostLibs or [];
              warnOnBinaryData = true;
            };
          qtPlugin = drv:
            mkBundle {
              inherit drv;
              name = drv.pname or drv.name or "bundle";
              extraDirs = drv.extraDirs or [];
              extraClosurePaths = drv.extraClosurePaths or [];
              hostLibs = (drv.hostLibs or []) ++ [ "Qt*" ];
              warnOnBinaryData = true;
            };
        });
    };
}
