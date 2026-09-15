{
  description = "heretical-historian — accretive history generator for occult societies";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  # The wasm32-wasi cross-compilation toolchain — wasm32-wasi-ghc/-cabal,
  # wasi-sdk (clang/wasm-ld), wasm-tools, binaryen, and node, all bundled
  # in its `default` package. Pinned to the exact revision docs/DESIGN.md
  # Decision 7/33 last verified the wasm boundary against, rather than
  # tracking its default branch — this toolchain is large, GHC-version-
  # specific, and the whole point of pinning is that a nixpkgs bump on the
  # main input never silently moves it out from under a working build.
  # Kept as a separate `wasm` devShell/app (below), not folded into the
  # default devShell: nothing else in this project needs it, and pulling
  # it in unconditionally would slow down `nix develop` for everyone else.
  inputs.ghc-wasm-meta.url = "git+https://gitlab.haskell.org/ghc/ghc-wasm-meta.git?rev=ef7acd4edfec5dd4b80b2228b625990aaf3cd4b7";

  outputs = { self, nixpkgs, ghc-wasm-meta }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];

      forAll = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

      # Pin the compiler here when you want reproducibility across nixpkgs
      # bumps, e.g. pkgs.haskell.packages.ghc984. The default tracks whatever
      # haskellPackages points at, which is fine for a project this small.
      hsPkgs = pkgs: pkgs.haskellPackages;

      historianFor = pkgs: (hsPkgs pkgs).callCabal2nix "heretical-historian" ./. { };

      # Only verified so far against x86_64-linux (docs/DESIGN.md Decision
      # 7/33); ghc-wasm-meta itself does publish packages for the other
      # three systems in `systems` above, so this is left un-gated rather
      # than hard-restricted — just don't assume aarch64-darwin etc. work
      # until someone actually tries it there.
      wasmToolsFor = system: ghc-wasm-meta.packages.${system}.default;
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

        # `nix run .#build-wasm` (run from the repo root — it works
        # against the checked-out source tree, not a hermetic Nix build of
        # it, the same way `wasm32-wasi-cabal build` always has here):
        # cross-compiles historian-wasm, patches it into a reactor-style
        # module (wasm/patch-reactor.sh), and re-verifies it end to end
        # against a real WASI host (wasm/verify.mjs) — the three ad hoc
        # `nix shell git+https://gitlab.haskell.org/ghc/ghc-wasm-meta.git`
        # commands docs/DESIGN.md Decision 7/33 used to require, now one
        # command. Still not a hermetic `nix build` of the .wasm itself —
        # modeling `wasm32-wasi-cabal`'s cross-compilation as a Nix
        # derivation is real, separate future work, not attempted here.
        build-wasm =
          let
            script = pkgs.writeShellApplication {
              name = "build-wasm";
              runtimeInputs = [ (wasmToolsFor pkgs.system) pkgs.findutils pkgs.gnugrep pkgs.gawk ];
              text = ''
                wasm32-wasi-cabal build historian-wasm
                built=$(find dist-newstyle/build/wasm32-wasi -name historian-wasm.wasm | head -n1)
                if [ -z "$built" ]; then
                  echo "historian-wasm.wasm not found after build — run this from the repo root" >&2
                  exit 1
                fi
                patched="$(dirname "$built")/historian-wasm.patched.wasm"
                bash wasm/patch-reactor.sh "$built" "$patched"
                node wasm/verify.mjs "$patched"
              '';
            };
          in
          {
            type = "app";
            program = "${script}/bin/build-wasm";
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

          # `nix develop .#wasm` — everything docs/DESIGN.md Decision 7/33
          # needed the ad hoc `nix shell git+https://gitlab.haskell.org/ghc/
          # ghc-wasm-meta.git` invocation for (wasm32-wasi-ghc/-cabal,
          # wasm-tools, node), now just part of this flake.
          wasm = pkgs.mkShellNoCC {
            packages = [ (wasmToolsFor pkgs.system) ];
          };
        });

      formatter = forAll (pkgs: pkgs.nixpkgs-fmt);
    };
}
