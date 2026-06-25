{
  description = "Sandboxed opencode sessions via Nix";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      supportedSystems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
      pkgsFor = system: import nixpkgs { inherit system; };
    in
    {
      packages = forAllSystems (system:
        let pkgs = pkgsFor system;
        in {
          # Bubblewrap wrapper + un-sandboxed opencode (both on PATH)
          default = pkgs.symlinkJoin {
            name = "opencode-sandbox";
            paths = [
              (pkgs.callPackage ./nix/backends/bubblewrap.nix { })
              pkgs.opencode
            ];
          };

          # Bubblewrap sandbox wrapper only
          sandbox = pkgs.callPackage ./nix/backends/bubblewrap.nix { };

          # Variant with network isolation
          no-network = pkgs.callPackage ./nix/backends/bubblewrap.nix {
            network = false;
          };
        });

      checks = forAllSystems (system: self.packages.${system});

      devShells = forAllSystems (system:
        let pkgs = pkgsFor system;
        in {
          default = pkgs.mkShell {
            packages = with pkgs; [ nixd nil nixpkgs-fmt ];
          };
        });
    };
}
