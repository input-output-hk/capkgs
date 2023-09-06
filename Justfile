# List available just tasks
list:
    just -l

# Update everything
update: releases packages

# Fetch versions specified in projects.json and update JSON in releases
releases:
    ./releases.nu

# Based on releases.json, upload the CA contents and update packages.json
packages *ARGS:
    ./packages.rb \
    --from https://cache.iog.io \
    --to "s3://devx?secret-key=/run/agenix/nix&endpoint=fc0e8a9d61fc1f44f378bdc5fdc0f638.r2.cloudflarestorage.com&region=auto&compression=zstd" \
    --systems x86_64-linux {{ARGS}}

# Attempt to build all packages from this flake
check:
    ./check.nu