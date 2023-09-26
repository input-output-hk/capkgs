# List available just tasks
list:
    just -l

# Based on releases.json, upload the CA contents and update packages.json
packages *ARGS:
    ./packages.rb \
    --from "s3://devx?profile=r2&secret-key=hydra_key&endpoint=fc0e8a9d61fc1f44f378bdc5fdc0f638.r2.cloudflarestorage.com&region=auto&compression=zstd" \
    --to "s3://devx?profile=r2&secret-key=hydra_key&endpoint=fc0e8a9d61fc1f44f378bdc5fdc0f638.r2.cloudflarestorage.com&region=auto&compression=zstd" \
    --systems x86_64-linux {{ARGS}}

# Attempt to build all packages from this flake
check:
    #!/usr/bin/env nu
    (
        nix eval .#packages.x86_64-linux --apply builtins.attrNames --json
        | from json
        | par-each {|p|
            nix build --no-link --print-out-paths $".#packages.x86_64-linux.($p)"
            | complete
        }
    )