{
  description = "Sandboxed opencode sessions via Nix";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    llm-agents = {
      url = "github:numtide/llm-agents.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, llm-agents }:
    let
      supportedSystems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
      pkgsFor = system: import nixpkgs { inherit system; };
    in
    {
      packages = forAllSystems (system:
        let
          pkgs = pkgsFor system;
          opencode = llm-agents.packages.${system}.opencode;
        in {
          # Bubblewrap wrapper + un-sandboxed opencode (both on PATH)
          default = pkgs.symlinkJoin {
            name = "opencode-sandbox";
            paths = [
              (pkgs.callPackage ./nix/backends/bubblewrap.nix { inherit opencode; })
              opencode
            ];
          };

          # Bubblewrap sandbox wrapper only
          sandbox = pkgs.callPackage ./nix/backends/bubblewrap.nix { inherit opencode; };

          # Variant with network isolation
          no-network = pkgs.callPackage ./nix/backends/bubblewrap.nix {
            inherit opencode;
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
