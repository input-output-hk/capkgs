# List available just tasks
list:
  just -l

# Update everything 
update: releases run

# Fetch releases, branches and tags specified in projects.json
releases:
  ./releases.nu

# Based on releases.json, upload the CA contents and update packages.json
run:
  ./run.rb --from https://cache.iog.io --to "s3://devx?secret-key=/run/agenix/nix&endpoint=fc0e8a9d61fc1f44f378bdc5fdc0f638.r2.cloudflarestorage.com&region=auto&compression=zstd" --systems x86_64-linux 