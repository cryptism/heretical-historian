{
  description = "heretical-historian — accretive history generator for occult societies";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];

      forAll = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

      # Pin the compiler here when you want reproducibility across nixpkgs
      # bumps, e.g. pkgs.haskell.packages.ghc984. The default tracks whatever
      # haskellPackages points at, which is fine for a project this small.
      hsPkgs = pkgs: pkgs.haskellPackages;

      historianFor = pkgs: (hsPkgs pkgs).callCabal2nix "heretical-historian" ./. { };
    in
    {
      packages = forAll (pkgs: {
        default = historianFor pkgs;
        heretical-historian = historianFor pkgs;
      });

      apps = forAll (pkgs: {
        default = {
          type = "app";
          program = "${historianFor pkgs}/bin/historian";
        };
      });

      devShells = forAll (pkgs:
        let hp = hsPkgs pkgs;
        in {
          default = hp.shellFor {
            packages = _: [ (historianFor pkgs) ];
            withHoogle = true;
            nativeBuildInputs = [
              hp.cabal-install
              hp.haskell-language-server
              hp.hlint
              hp.fourmolu
              pkgs.ghcid
            ];
          };
        });

      formatter = forAll (pkgs: pkgs.nixpkgs-fmt);
    };
}
