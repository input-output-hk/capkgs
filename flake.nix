{
  outputs = inputs: let
    inherit
      (builtins)
      attrNames
      attrValues
      elemAt
      fetchClosure
      foldl'
      fromJSON
      getFlake
      readFile
      split
      substring
      ;

    inherit
      (import ./lib.nix)
      aggregate
      filterAttrs
      last
      mapAndMergeAttrs
      optionalAttr
      sane
      symlinkPath
      ;

    # This is a really verbose name, but it ensures we don't get collisions
    nameOf = flakeUrl: pkg: let
      fragment = split "#" flakeUrl;
      parts = split "\\." (last fragment);
      name = last parts;
      shortrev = substring 0 7 pkg.commit;
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
              path = fetchClosure {
                inherit (pkg.closure) fromPath fromStore;
                inputAddressed = true;
              };
            }
            // (optionalAttr pkg "exeName"));
        }
      )
      validPackages;

    system = "x86_64-linux";

    # These inputs are purely used for the devShell and hydra to avoid any
    # evaluation and download of nixpkgs for just building a package.
    flakes = {
      nixpkgs = getFlake "github:nixos/nixpkgs?rev=bfb7dfec93f3b5d7274db109f2990bc889861caf";
      nix = getFlake "github:nixos/nix?rev=9e212344f948e3f362807581bfe3e3d535372618";
    };

    # At least 2.17 is required for this fix: https://github.com/NixOS/nix/pull/4282
    inherit (flakes.nix.packages.${system}) nix;
  in
    {
      hydraJobs = {
        required = aggregate {
          name = "required";
          constituents = attrValues inputs.self.packages.x86_64-linux;
        };

        recovery = aggregate {
          name = "recovery";
          constituents = map (
            a: let
              parts = split "#" a;
              flake = getFlake (elemAt parts 0);
              attr = elemAt parts 2;
              path = split "\\." attr;
            in
              foldl' (
                s: v:
                  if v == []
                  then s
                  else s.${v}
              )
              flake
              path
          ) (attrNames validPackages);
        };
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

          shellHook = let
            pre-push = writeShellApplication {
              name = "pre-push";
              text = ''
                if ! jq -e < projects.json &> /dev/null; then
                  echo "ERROR: Invalid JSON found in projects.json"
                  exit 1
                fi
              '';
            };
          in ''
            if [ -z "$CI" ] && [ -d .git/hooks ] && ! [ -f .git/hooks/pre-push ]; then
              ln -s ${pre-push}/bin/pre-push .git/hooks/pre-push
            fi
          '';
        };
    }
    // packages;
}
