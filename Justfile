# List available just tasks
list:
    just -l

export RCLONE_S3_PROVIDER := "Cloudflare"
export RCLONE_S3_REGION := "auto"

# Based on releases.json, upload the CA contents and update packages.json
packages *ARGS:
    ./packages.cr \
        --from "https://cache.iog.io" \
        --to "s3://devx?secret-key=hydra_key&endpoint=${S3_ENDPOINT}&region=${RCLONE_S3_REGION}&compression=zstd" \
        --nix-store "${NIX_SSH_NG_STORE}" \
        --systems x86_64-linux {{ARGS}}

# Based on releases.json, upload the CA contents and update packages.json
ci:
    rclone --s3-endpoint ${S3_ENDPOINT} --verbose copy s3://devx/capkgs cache
    ./packages.cr \
        --from "https://cache.iog.io" \
        --to "s3://devx?secret-key=hydra_key&endpoint=${S3_ENDPOINT}&region=${RCLONE_S3_REGION}&compression=zstd" \
        --nix-store "${NIX_SSH_NG_STORE}" \
        --systems x86_64-linux {{ARGS}}
    rclone --s3-endpoint ${S3_ENDPOINT} --verbose sync cache s3://devx/capkgs

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