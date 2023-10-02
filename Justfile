# List available just tasks
list:
    just -l

# Based on releases.json, upload the CA contents and update packages.json
packages *ARGS:
    ./packages.cr \
        --to "s3://devx?secret-key=hydra_key&endpoint=${S3_ENDPOINT}&region=auto&compression=zstd" \
        --from-store https://cache.iog.io \
        --nix-store "${NIX_STORE}" \
        --systems x86_64-linux

# Based on releases.json, upload the CA contents and update packages.json
ci:
    just rclone copy s3://devx/capkgs cache
    just packages
    just rclone sync cache s3://devx/capkgs

rclone *ARGS:
    #!/usr/bin/env nu
    $env.HOME = $env.PWD
    mkdir .config/rclone
    rclone config create s3 s3 env_auth=true | save -f .config/rclone/rclone.conf
    rclone --s3-provider Cloudflare --s3-region auto --s3-endpoint $env.S3_ENDPOINT --verbose {{ARGS}}
    

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