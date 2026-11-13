# 0002 CI runs on the maintained Ruby versions

**Status:** Accepted

## Decision

The CI matrix contains only the Ruby versions that ruby-lang.org lists as
maintained, each with three versions of the uri gem: the one shipped with that
Ruby, `< 1.0` and `~> 1.0`.

On 2026-11-13 the maintained versions are 3.3, 3.4 and 4.0
([branches](https://www.ruby-lang.org/en/downloads/branches/)).

## Why

- A version past its end of life gets no fixes, and its toolchain stops building
  on current CI images. A red job there says nothing about the gem.
- The uri gem changed its default parser in 1.0, and the gem patches the parser
  of older versions. Both code paths need a job.

## Consequences

- When a Ruby version reaches its end of life it leaves the matrix; when a new
  one is released it enters.
- The gemspec declares `required_ruby_version >= 2.7.0`, which is wider than what
  CI verifies. Versions from 2.7 to 3.2 are allowed and untested. The floor moves
  to the oldest maintained version in 3.0, see the [roadmap](../ROADMAP.md).
- Until then, code must stay within Ruby 2.7 syntax.
