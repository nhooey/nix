---
synopsis: "Fix locking of relative `path:` inputs in nested flakes"
issues: [14762]
prs: [15982]
---

Locking a flake no longer fails with `path '.../flake.nix' does not exist`
when one of its inputs has its own lock file, and an input in that lock file
has a relative `path:` input, or one that an intermediate flake overrides
with a relative path. When the wrong flake had a directory of that name, the
command doing the locking used to evaluate it instead of failing, though the
lock file it wrote was correct. The relative input is now taken from the
nested flake's lock file and resolved against the flake it is relative to.
