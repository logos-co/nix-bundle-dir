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
              hostLibs = drv.hostLibs or [];
              warnOnBinaryData = true;
              guiApp = false;
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
