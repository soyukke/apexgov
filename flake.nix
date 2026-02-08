{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { nixpkgs, flake-utils, ... }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
      in
      {
        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            zig
            zls
            jdk21_headless
          ];
          shellHook = ''
            if [ -z "''${XDG_CACHE_HOME:-}" ]; then
              export XDG_CACHE_HOME="$PWD/.cache"
            fi
            mkdir -p "$XDG_CACHE_HOME"
          '';
        };
      }
    );
}
