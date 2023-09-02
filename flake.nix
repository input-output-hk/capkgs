{
  outputs = inputs: let
    inherit (builtins) fromJSON readFile fetchClosure;
    inherit (import ./lib.nix) filterAttrs symlinkPath sane mapAndMergeAttrs;

    # This is a really verbose name, but it ensures we don't get collisions
    nameOf = pkg: sane "${pkg.org}-${pkg.repo}-${pkg.tag}-${pkg.meta.name}";

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

    devShellSystem = "x86_64-linux";
  in
    {
      devShells.${devShellSystem}.default = let
        # These inputs are purely used for the devShell to avoid any evaluation and download of
        # nixpkgs for just building a package.
        nixpkgsFlake = builtins.getFlake "github:nixos/nixpkgs?rev=04a75b2eecc0acf6239acf9dd04485ff8d14f425";
        inherit (nixpkgsFlake.legacyPackages.${devShellSystem}) mkShell nushell just ruby treefmt;

        # At least 2.17 is required for this fix: https://github.com/NixOS/nix/pull/4282
        nixFlake = builtins.getFlake "github:nixos/nix?rev=8fbb4598c24b89c73db318ca7de7f78029cd61f4";
        inherit (nixFlake.packages.${devShellSystem}) nix;
      in
        mkShell {
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
