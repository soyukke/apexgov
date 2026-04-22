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
          # zig / zls は home-manager (zig-overlay) 側で 0.16 を pin しているのでそちらを使う。
          # この flake 内で pkgs.zig を追加すると nixpkgs デフォルト (0.15.2) が PATH 先頭に来て
          # 上書きされるため、あえて入れない。
          buildInputs = with pkgs; [
            jdk21_headless
          ];
          shellHook = ''
            if [ -z "''${XDG_CACHE_HOME:-}" ]; then
              export XDG_CACHE_HOME="$PWD/.cache"
            fi
            export ZIG_GLOBAL_CACHE_DIR="$XDG_CACHE_HOME/zig-global"
            export ZIG_LOCAL_CACHE_DIR="$PWD/.zig-cache"
            mkdir -p "$XDG_CACHE_HOME" "$ZIG_GLOBAL_CACHE_DIR" "$ZIG_LOCAL_CACHE_DIR"
          '';
        };
      }
    );
}
