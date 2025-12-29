{
  outputs = inputs: let
    inherit
      (builtins)
      attrValues
      elemAt
      fetchClosure
      filter
      foldl'
      fromJSON
      getFlake
      isString
      readFile
      replaceStrings
      split
      substring
      ;

    inherit
      (import ./lib.nix)
      aggregate
      filterAttrs
      last
      mapAndMergeAttrs
      mapAttrs'
      nameValuePair
      optionalAttr
      removePrefix
      removeSuffix
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
    flakes.nixpkgs = getFlake "github:nixos/nixpkgs?rev=9ef261221d1e72399f2036786498d78c38185c46";
    inherit (flakes.nixpkgs.legacyPackages.${system}) nix;
  in
    {
      hydraJobs =
        {
          required = aggregate {
            name = "required";
            constituents = attrValues inputs.self.packages.x86_64-linux;
          };
        }
        // (mapAttrs' (
            url: pkg: let
              parts = split "#" url;
              flake = getFlake (elemAt parts 0);
              attr = elemAt parts 2;
              path = filter isString (split "\\." attr);
              withoutQuote = str: removePrefix "\"" (removeSuffix "\"" str);
              jobName = replaceStrings [":" "/" "#" "." "\""] ["-colon-" "-slash-" "-pound-" "-dot-" ""];
            in
              nameValuePair (jobName url) (foldl' (
                  s: v:
                    s.${v} or
                    s.${withoutQuote v} or
                    s.packages.${pkg.system}.${v} or
                    s.packages.${pkg.system}.${withoutQuote v} or
                    s.legacyPackages.${pkg.system}.${v} or
                    s.legacyPackages.${pkg.system}.${withoutQuote v} or
                    (throw "couldn't find ${attr} in ${elemAt parts 0}")
                )
                flake
                path)
          )
          validPackages);

      devShells.${system}.default = with (flakes.nixpkgs.legacyPackages.${system});
        mkShell {
          nativeBuildInputs = [
            crystal
            crystalline
            curl
            gitMinimal
            just
            nix
            pcre
            rclone
            treefmt
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
