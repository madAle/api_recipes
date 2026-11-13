# 0003 Releases and versioning

**Status:** Accepted

## Decision

- Versions follow semantic versioning: a change that can break existing code
  goes in a major version.
- Branches follow git-flow: `develop`, `master`, `feature/*`, `release/*`.
- Git tags are `vX.Y.Z`. The version on RubyGems is `X.Y.Z`.
- A release is pushed and published only after CI is green on the branch.

## Why

- `rake release` creates and expects tags with the `v` prefix. Using the same
  prefix in git-flow avoids two tags for one release.
- CI runs on feature and release branches, so a failure shows before the merge
  into `develop`.
- A version number published on RubyGems cannot be reused: publishing is the one
  step that cannot be undone.

## Consequences

- Defects whose fix changes behaviour wait for the next major version, even
  when the fix is small. They are listed in the [roadmap](../ROADMAP.md).
- `CHANGELOG.md` has an `Unreleased` section at the top, renamed at release time.
- The steps of a release are in [CLAUDE.md](../../CLAUDE.md).
