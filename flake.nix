{
  outputs = inputs: let
    inherit (builtins) fromJSON readFile fetchClosure attrValues;
    inherit (import ./lib.nix) filterAttrs symlinkPath sane mapAndMergeAttrs aggregate optionalAttr last;

    # This is a really verbose name, but it ensures we don't get collisions
    nameOf = flakeUrl: pkg: let
      fragment = builtins.split "#" flakeUrl;
      parts = builtins.split "\\." (last fragment);
      name = last parts;
      shortrev = builtins.substring 0 7 pkg.commit;
    in
      sane "${name}-${pkg.org_name}-${pkg.repo_name}-${pkg.version}-${shortrev}";

    packagesJson = fromJSON (readFile ./packages.json);
    validPackages = filterAttrs (flakeUrl: pkg: pkg ? system && !(pkg ? fail)) packagesJson;
    packages =
      mapAndMergeAttrs (
        flakeUrl: pkg: {
          packages.${pkg.system}.${nameOf flakeUrl pkg} = symlinkPath ({
              inherit (pkg) pname version meta system;
              name = pkg.meta.name;
              path = fetchClosure pkg.closure;
            }
            // (optionalAttr pkg "exeName"));
        }
      )
      validPackages;

    system = "x86_64-linux";

    # These inputs are purely used for the devShell and hydra to avoid any
    # evaluation and download of nixpkgs for just building a package.
    flakes = {
      nixpkgs = builtins.getFlake "github:nixos/nixpkgs?rev=bfb7dfec93f3b5d7274db109f2990bc889861caf";
      nix = builtins.getFlake "github:nixos/nix?rev=9e212344f948e3f362807581bfe3e3d535372618";
    };

    # At least 2.17 is required for this fix: https://github.com/NixOS/nix/pull/4282
    inherit (flakes.nix.packages.${system}) nix;
  in
    {
      hydraJobs.required = aggregate {
        name = "required";
        constituents = attrValues inputs.self.packages.x86_64-linux;
      };

      devShells.${system}.default = with (flakes.nixpkgs.legacyPackages.${system});
        mkShell {
          nativeBuildInputs = [
            crystal
            crystalline
            curl
            gitMinimal
            just
            nix
            nushell
            pcre
            rclone
            treefmt
            watchexec
            gnutar
            zstd
          ];
        };
    }
    // packages;
}
