# 0001 Specs never use the network

**Status:** Accepted

## Decision

Specs stub HTTP with WebMock and `WebMock.disable_net_connect!` is always on.
Global state is cleared with `ApiRecipes.reset!` before each example.

## Why

- The suite runs offline, in a fraction of a second, and gives the same result
  on CI and on a laptop.
- A request the code should not make fails the example instead of reaching a
  real server.
- WebMock checks the request as http.rb sends it (verb, URL, query, headers,
  body), so specs describe what a server would receive, not internal calls.

## Consequences

- The scripts in `examples/` are the only code that calls real APIs. They are
  run by hand.
- A stubbed response needs a `Content-Type` for `response.data` to parse it.
- Specs for existing behaviour are characterization specs: they pass without
  changes under `lib/`. They do not pin the known defects listed in the
  [roadmap](../ROADMAP.md), so that fixing one does not require deleting a spec.
