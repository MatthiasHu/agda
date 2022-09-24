{
  description = "Agda is a dependently typed programming language / interactive theorem prover.";

  inputs.flake-utils.url = "github:numtide/flake-utils";

  outputs = { self, nixpkgs, flake-utils }: (flake-utils.lib.eachDefaultSystem (system: let
    pkgs = import nixpkgs { inherit system; overlays = [ self.overlay ]; };
  in {
    packages = {
      inherit (pkgs.haskellPackages) Agda;

      # TODO agda2-mode
    };

    defaultPackage = self.packages.${system}.Agda;

    devShell = pkgs.mkShell {
      inputsFrom = [ self.defaultPackage.${system} ];
      packages = with pkgs; [
        pkg-config
        zlib
        icu
        haskellPackages.fix-whitespace
      ];
    };
  })) // {
    overlay = final: prev: {
      haskellPackages = prev.haskellPackages.override {
        overrides = self.haskellOverlay;
      };
    };

    haskellOverlay = final: prev: let
      inherit (final) callCabal2nixWithOptions;

      shortRev = builtins.substring 0 9 self.rev;

      postfix = if self ? revCount then "${toString self.revCount}_${shortRev}" else "Dirty";

      # TODO use separate evaluation system?
      AgdaWithOptions = options: callCabal2nixWithOptions "Agda" ./. options ({
        mkDerivation = args: final.mkDerivation (args // {
          version = "${args.version}-pre${postfix}";

          postInstall = "$out/bin/agda-mode compile";

          # TODO Make check phase work
          # At least requires:
          #   Setting AGDA_BIN (or using the Makefile, which at least requires cabal-install)
          #   Making agda-stdlib available (or disabling the relevant tests somehow)
          doCheck = false;
        });
      });

    in {
      Agda = AgdaWithOptions "--flag enable-cluster-counting --flag optimise-heavily";

      # An alternative flake output that compiles faster, mostly for faster testing in CI,
      # see src/github/workflows/nix.yml .
      AgdaNonOptimized = AgdaWithOptions "--flag enable-cluster-counting";
    };
  };
}
