# List available just tasks
list:
    just -l

secret_key := env_var_or_default('NIX_SIGNING_KEY_FILE', "hydra_key")

# Based on projects.json, upload the CA contents and update packages.json
packages *ARGS:
    ./packages.cr \
        --to "s3://devx?secret-key={{secret_key}}&endpoint=${S3_ENDPOINT}&region=auto&compression=zstd" \
        --from-store https://cache.iog.io \
        --systems x86_64-linux

# Based on projects.json, upload the CA contents and update packages.json
ci:
    @just -v cache-download
    @just -v packages
    @just -v cache-upload

# download and uncompress the cache folder
cache-download:
    @just -v rclone copyto s3://devx/capkgs/cache.tar.zst cache.tar.zst
    tar xf cache.tar.zst

# compress and upload the cache folder
cache-upload:
    tar cfa cache.tar.zst cache
    @just -v rclone copyto cache.tar.zst s3://devx/capkgs/cache.tar.zst

rclone *ARGS:
    #!/usr/bin/env nu
    if $env.CI? == "true" { $env.HOME = $env.PWD }
    mkdir .config/rclone
    rclone config create s3 s3 env_auth=true | save -f .config/rclone/rclone.conf
    rclone --s3-provider Cloudflare --s3-region auto --s3-endpoint $env.S3_ENDPOINT --verbose {{ARGS}}

push:
    git add packages.json
    git commit -m 'Update packages.json'

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
