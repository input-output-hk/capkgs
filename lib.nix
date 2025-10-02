let
  inherit
    (builtins)
    attrNames
    concatMap
    elemAt
    fetchClosure
    foldl'
    hasAttr
    head
    isAttrs
    length
    listToAttrs
    replaceStrings
    stringLength
    substring
    zipAttrsWith
    ;

  # x86-64-linux
  busybox = fetchClosure {
    fromPath = "/nix/store/62z5dklpfq7n0wi5fdasf4y0ymy12nxg-busybox-1.36.1";
    toPath = "/nix/store/r4nhqzdi024kqw6riwpghidhyp2kdvfw-busybox-1.36.1";
    fromStore = "https://cache.nixos.org";
  };

  # This way we avoid depending on nixpkgs just to turn our store paths from
  # `fetchClosure` back into derivations
  symlinkPath = args:
    (derivation {
      inherit (args) name system;
      builder = "${busybox}/bin/ln";
      args = ["-s" args.path (placeholder "out")];
      pathToLink = args.path;
    })
    // args;

  aggregate = {
    name,
    constituents,
    meta ? {},
  }: let
    script = ''
      mkdir -p $out/nix-support
      touch $out/nix-support/hydra-build-products
      echo $constituents > $out/nix-support/hydra-aggregate-constituents

      for i in $constituents; do
        if [ -e $i/nix-support/failed ]; then
          touch $out/nix-support/failed
        fi
      done
    '';
  in
    (derivation {
      inherit name constituents;
      system = "x86_64-linux";
      preferLocalBuild = true;
      _hydraAggregate = true;
      PATH = "${busybox}/bin";
      builder = "${busybox}/bin/sh";
      args = ["-c" script];
    })
    // {inherit meta;};

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

  mapAttrs' = f: set: listToAttrs (mapAttrsToList f set);

  nameValuePair = name: value: {inherit name value;};

  optionalAttr = attrs: name:
    if hasAttr name attrs
    then {${name} = attrs.${name};}
    else {};

  last = list: elemAt list ((length list) - 1);

  removePrefix = prefix: str: let
    preLen = stringLength prefix;
  in
    if substring 0 preLen str == prefix
    then substring preLen (-1) str
    else str;

  removeSuffix = suffix: str: let
    sufLen = stringLength suffix;
    sLen = stringLength str;
  in
    if sufLen <= sLen && suffix == substring (sLen - sufLen) sufLen str
    then substring 0 (sLen - sufLen) str
    else str;
in {
  inherit
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
}
