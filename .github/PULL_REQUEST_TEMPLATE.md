<!-- Thanks for the PR. main is PR-gated: the `ci-linux` check must pass to merge. -->

## What & why

<!-- One or two lines: what changes, and what it's for. -->

## Changes

-

## Pack contract

- [ ] This change does **not** alter the shape of a pack, **or**
- [ ] It does, and `schemas/pack.schema.json` is updated in this PR

## Checklist

- [ ] `cargo fmt` clean, `clippy -D warnings` clean, `cargo test` passing
- [ ] `npm run build` succeeds
- [ ] Privacy contract intact (no capture under secure input; concealed clipboard skipped)
- [ ] Verified on a real Mac if it touches capture (CI can't exercise capture)
