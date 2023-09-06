{
  outputs = inputs: let
    inherit (builtins) fromJSON readFile fetchClosure attrValues;
    inherit (import ./lib.nix) filterAttrs symlinkPath sane mapAndMergeAttrs aggregate;

    # This is a really verbose name, but it ensures we don't get collisions
    nameOf = pkg: sane "${pkg.meta.name}-${pkg.org}-${pkg.repo}-${pkg.tag}";

    packagesJson = fromJSON (readFile ./packages.json);
    validPackages = filterAttrs (flakeUrl: pkg: pkg ? system && !(pkg ? fail)) packagesJson;
    packages =
      mapAndMergeAttrs (
        flakeUrl: pkg: {
          packages.${pkg.system}.${nameOf pkg} = symlinkPath {
            inherit (pkg) pname version meta system;
            name = pkg.meta.name;
            path = fetchClosure pkg.closure;
          };
        }
      )
      validPackages;

    system = "x86_64-linux";
    flakes = {
      nixpkgs = builtins.getFlake "github:nixos/nixpkgs?rev=bfb7dfec93f3b5d7274db109f2990bc889861caf";
      nix = builtins.getFlake "github:nixos/nix?rev=8fbb4598c24b89c73db318ca7de7f78029cd61f4";
    };

    # These inputs are purely used for the devShell and hydra to avoid any
    # evaluation and download of nixpkgs for just building a package.
    inherit (flakes.nixpkgs.legacyPackages.${system}) mkShell nushell just ruby treefmt;

    # At least 2.17 is required for this fix: https://github.com/NixOS/nix/pull/4282
    inherit (flakes.nix.packages.${system}) nix;
  in
    {
      hydraJobs.required = aggregate {
        name = "required";
        constituents = attrValues inputs.self.packages.x86_64-linux;
      };

      devShells.${system}.default = mkShell {
        nativeBuildInputs = [
          nushell
          just
          ruby
          nix
          treefmt
        ];
      };
    }
    // packages;
}
