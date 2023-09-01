let
  inherit (builtins) attrNames concatMap elemAt fetchClosure foldl' head isAttrs length listToAttrs replaceStrings zipAttrsWith;

  # This way we avoid depending on nixpkgs just to turn our store paths from
  # `fetchClosure` back into derivations
  symlinkPath = args: let
    busybox = fetchClosure {
      fromPath = "/nix/store/62z5dklpfq7n0wi5fdasf4y0ymy12nxg-busybox-1.36.1";
      toPath = "/nix/store/r4nhqzdi024kqw6riwpghidhyp2kdvfw-busybox-1.36.1";
      fromStore = "https://cache.nixos.org";
    };
  in
    (derivation {
      inherit (args) name system;
      builder = "${busybox}/bin/ln";
      args = ["-s" args.path (placeholder "out")];
      pathToLink = args.path;
    })
    // args;

  sane = replaceStrings ["."] ["-"];

  filterAttrs = pred: set:
    listToAttrs (concatMap (name: let
      value = set.${name};
    in
      if pred name value
      then [{inherit name value;}]
      else []) (attrNames set));

  mapAttrsToList = f: attrs:
    map (name: f name attrs.${name}) (attrNames attrs);

  recursiveUpdateUntil = pred: lhs: rhs: let
    f = attrPath:
      zipAttrsWith (
        n: values: let
          here = attrPath ++ [n];
        in
          if
            length values
            == 1
            || pred here (elemAt values 1) (head values)
          then head values
          else f here values
      );
  in
    f [] [rhs lhs];

  recursiveUpdate = lhs: rhs:
    recursiveUpdateUntil (path: lhs: rhs: !(isAttrs lhs && isAttrs rhs)) lhs rhs;

  mapAndMergeAttrs = f: attrs: foldl' recursiveUpdate {} (mapAttrsToList f attrs);
in {
  inherit filterAttrs mapAndMergeAttrs sane symlinkPath;
}
