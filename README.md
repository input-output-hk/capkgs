# Content Addressed Packages

A collection of content-addressed package closures.

## Purpose

This project aims to speed up development environment setup, reduce disk and CPU
usage, and provide a smoother onboarding experience.

That's achieved by evaluating and building, then converting them into their
content-addressed form using `nix store make-content-addressed`.

In this process, Nix calculates the hashes of the final output, as opposed
to the default where the hash is calculated based on the attributes of a
derivation.

Once the final hash is known, no other user has to download the sources and run
the evaluation steps anymore, and they can fully trust the cache if the hash
matches.

In a sense, this does for Nix programs what Nix does for other programs.

Naturally, only packages that were actually built successfully are available in this fashion.

## Usage

At the moment, this requires the experimental `fetch-closure` feature of Nix.
You can enable it using the `--extra-experimental-features` flag, or in your configuration.
Additionally, this flake will only work with the `flakes` feature, although you
may fetch the `packages.json` from this repo and use the `closure` attribute to
pass to `fetchClosure` with traditional Nix.

Packages are referenced by a `<org>/<repo>/<version>/<name>` schema.

    {
      inputs.capkgs.url = "github:input-output-hk/capkgs";
      outputs = {capkgs, ...}: {
        packages.x86_64-linux.cardano-node =
         capkgs.packages.x86_64-linux.input-output-hk-cardano-node-8-2-0-pre-cardano-node-exe-cardano-node-8-2-0;
      };
    }

## Packages

The list of packages we provide lives in `packages.json`, only packages without
the `fail` attribute are considered. We keep the information about failed
packages around to avoid attempts of rebuilding them which would consume vast
amounts of time.

This list is derived from the `projects.json`, where we declare which packages
from which repository we would like to have.

Ideally a repository follows a sensible release process, and we can just use
that as basis for our versioning, but when that is not the case, there are other
strategies, based on tag patterns or bare branch names.

## GitHub Actions

`PR checks` validates JSON metadata, type-checks the Crystal updater, and checks
Nix syntax without publishing credentials. Fork PRs run with a read-only token;
configure GitHub's fork-workflow approval settings if maintainer approval is
required. For manual PR checks, dispatch this workflow from reviewed `main` code
with both `pr_number` and its full reviewed `head_sha`. A changed PR head is
rejected. These checks do not run the complete package build and upload cycle.

`Update` publishes cache contents and commits package metadata only on `main`,
through pushes, scheduled runs, or manual dispatch without PR inputs. Protect
`main` with required review, including workflow changes, and restrict bypass
permissions in repository settings. Merge reviewed changes before publishing;
do not run the updater with publishing credentials against fork code.

Publishing runs are serialized. A queued run skips building and uploading if
`main` has advanced beyond its triggering commit. A concurrent change to `main`
during an active build can still cause the final Git push to be rejected; rerun
the update from current `main` in that case.

## TODO

- [ ] Provide more statically compiled `musl` packages and nuke their references to the Nix store to allow even smaller closures.
- [ ] Make the update scripts generally useful as a tool for the community.
- [ ] Improve naming of packages, although verbose, it still may have collisions.
- [ ] Run periodically on Hydra to populate our cache.
- [ ] Automatically update this repo.
- [ ] Maybe an easier way to force rebuilding specific packages.
- [ ] Record _why_ a specific package is marked as failed, not just that it did. 
- [ ] validate projects.json syntax before starting
