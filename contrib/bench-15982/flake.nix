{
  description = "Benchmark for NixOS/nix#15982: nix flake lock, baseline vs candidate";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { nixpkgs, ... }:
    let
      forAllSystems = nixpkgs.lib.genAttrs [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];
    in
    {
      packages = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          default = pkgs.writeShellApplication {
            name = "bench";
            runtimeInputs = [
              pkgs.coreutils
              pkgs.gnugrep
            ];
            text = builtins.readFile ./bench.sh;
          };
        }
      );
    };
}
