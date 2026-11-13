# api_recipes

A Ruby gem that turns a YAML description of an HTTP API into a chain of Ruby
methods (`ApiRecipes.github.users.show('octocat').run`). Requests are made with
http.rb. User documentation is in [README.md](README.md).

## Commands

```sh
bundle install
bundle exec rspec                               # whole suite, no network
bundle exec rspec spec/unit/url_building_spec.rb
bundle exec rspec spec/security                 # one example per protection
bundle exec rspec spec/docs                     # the examples in README.md and UPGRADING.md
bundle exec ruby -Ilib exe/api_recipes upgrade app lib --config config/apis/github.yml
URI_VERSION='~> 1.0' bundle exec rspec          # pick the uri gem: '~> 1.0' or '< 1.0'
gem build api_recipes.gemspec -o /tmp/check.gem # packaging check
```

SimpleCov writes the coverage report to `coverage/` at every run. On CI the suite
fails under 90% line coverage.

## Layout

| Path | Role |
| --- | --- |
| `lib/api_recipes.rb` | the `api` class macro, `configure`, `[]`, `apis`, `reset!`, `logger` |
| `lib/api_recipes/configuration.rb` | options of `ApiRecipes.configure`, YAML and ERB loading, logger |
| `lib/api_recipes/api.rb` | `Api`: what `ApiRecipes.github` returns; root endpoints, `with`, credentials, variables |
| `lib/api_recipes/endpoint.rb` | `Endpoint`: one step of the chain; builds the path, `run`, `url`, `with` |
| `lib/api_recipes/response.rb` | wraps the http.rb response and adds `data`, `success?`, `fill` |
| `lib/api_recipes/errors.rb` | error classes, all under `ApiRecipes::Error` |
| `lib/api_recipes/core/definition.rb` | the immutable tree that `definition` returns |
| `lib/api_recipes/core/compiler.rb` | turns the configuration into a tree and validates it; reports every problem at once |
| `lib/api_recipes/core/path_template.rb`, `template.rb` | the `path` of an endpoint, and `{variable}` strings, with their encoding rules |
| `lib/api_recipes/core/handles.rb` | generates the subclasses of `Api` and `Endpoint` with one method per child |
| `lib/api_recipes/core/context.rb` | which tree, which owner and which `with` options a chain uses; resolves values |
| `lib/api_recipes/core/level.rb`, `credential.rb` | credentials and variables assigned to the module, a class or an object |
| `lib/api_recipes/core/registry.rb` | what `configure` produced, swapped in at once; the global apis |
| `lib/api_recipes/core/declaration.rb` | one `api :name` in a class or a module |
| `lib/api_recipes/core/request.rb` | builds the URL and the http.rb client, sends the request, checks the outcome |
| `lib/api_recipes/cli.rb`, `cli/upgrade.rb`, `exe/api_recipes` | the `api_recipes` command and its `upgrade` checks |
| `spec/unit`, `spec/integration` | specs; integration specs stub HTTP with WebMock |
| `spec/security` | one example per protection, and `README.md` that maps them |
| `spec/docs/examples_spec.rb` | evaluates the examples of README.md and UPGRADING.md |
| `spec/support/test_apis.rb` | shared configuration and helpers for specs |
| `spec/fixtures` | YAML files for configuration specs |
| `examples` | runnable scripts that call public APIs |
| `README.md`, `UPGRADING.md` | the user guide, and the guide for people coming from 2.x |
| `docs/ROADMAP.md` | what the next versions contain |

## How a call works

1. `ApiRecipes.configure` loads the sources, compiles them into one immutable tree
   per api and validates them. Only if that succeeds is the new registry swapped
   in, together with one method per api on the `ApiRecipes` module. `api :name`
   in a class or a module defines the same method on it and on its instances.
2. That method returns an `Api`. Each endpoint method returns a new `Endpoint`
   that knows its node of the tree and its path, built from the parent path, its
   own `path` and the arguments. `[]` does the same by name, and the generated
   methods call it.
3. Credentials and variables are not kept on these objects. They live in levels
   attached to the owner of the call (the module, a class, an instance) and are
   read, nearest first, when the request is built. `with` adds a level for one chain.
4. `run`, or a block, creates a `Core::Request`, which builds the URL and the http.rb
   client, sends the request, checks the outcome (`ok_code`, `on_bad_code`,
   `verify_with`) and returns a `Response`.

Objects of the chain are created again at every step. The tree and the generated
classes are built once, by `configure`.

## Rules for changes

- Specs never use the network: `WebMock.disable_net_connect!` stays on.
- A spec for existing behaviour must pass without touching `lib/`.
- A behaviour change comes with its spec, written first.
- Internal classes live under `ApiRecipes::Core`, so that `include ApiRecipes` does not shadow an application's own constants. Only `Api`, `Endpoint`, `Response`, `Configuration`, the errors and `VERSION` stay directly under `ApiRecipes`.
- Ruby 3.3 syntax; the block parameter `it` is not allowed (Ruby 3.4).
- `Api` and `Endpoint` have only these public methods. `Api`: `[]`, `with`,
  `definition`, `authorization`, `authorization=`, `basic_auth`, `basic_auth=`,
  `variables`, `variables=`, `inspect`. `Endpoint`: `[]`, `run`, `url`, `with`,
  `definition`, `inspect`. Both also have `marshal_dump`, `encode_with`,
  `as_json` and `to_json`, which refuse serialization. Nothing else: every method
  is a name that an endpoint cannot use. Their state lives in instance variables,
  and inside their instance methods the only private Kernel methods called are
  `raise` and `block_given?`.
- Every protection has an example under `spec/security` and a row in
  `spec/security/README.md`. A spec for a protection must fail when the
  protection is removed.
- Never put a credential, a header, a body or a query string in a log line, an
  error message, `inspect` or `definition`.
- A regular expression that validates a name or a value uses `\A` and `\z`, never
  `^` and `$`.
- Do not add monkey patches. `logger` and `http` are the only runtime
  dependencies.
- Every code example in the README and in UPGRADING.md must be true.
  `spec/docs/examples_spec.rb` evaluates each line of Ruby that is directly
  followed by a `# => "..."` line, so write a result that can be checked in that
  form, and check the other statements by hand against the library.
- Repository content is in English. Commit messages are in English, imperative,
  with no prefix and no trailer, for example `Bump version number`.
- Do not use the em dash character in any file.

## Spec helpers

`spec/spec_helper.rb` calls `ApiRecipes.reset!` before each example and includes
`TestApis`:

- `configure_test_apis(apis = TEST_APIS)` configures ApiRecipes with a silent logger.
- `new_client_class` returns an anonymous class that declares the `svc` and
  `versioned` test apis.
- `base_url` is `https://api.example.test`, the host of the `svc` test api.

Helpers are methods, not constants: a constant of the module is not visible
from an example.

## Releases

The repository uses git-flow: `develop` and `master`, branches `feature/*` and
`release/*`. Tags have the `v` prefix; versions on RubyGems do not.

1. Finish the feature branch into `develop`.
2. Start `release/X.Y.Z`. Rename the `Unreleased` section of `CHANGELOG.md` and
   set `VERSION` in `lib/api_recipes/version.rb`.
3. Merge into `master`, create the annotated tag `vX.Y.Z` with message
   `Version X.Y.Z`, merge back into `develop`, delete the release branch.
   Do these steps by hand: `git flow release finish -m` fails on macOS when the
   message contains spaces.
4. `git push origin master develop vX.Y.Z`, then `bundle exec rake release`
   from `master`.

Never push, tag on the remote or publish without the explicit confirmation of
the maintainer. A version number published on RubyGems cannot be reused.

## Things that surprise

- CI runs on every push to `develop`, `master`, `feature/**`, `release/**` and
  `hotfix/**`: push the branch and read the jobs before merging.
- CI tests only the Ruby versions that are still maintained.
- The "already initialized constant Gem::Platform" warnings printed by Bundler
  come from the local installation, not from the project.
- With two versions of the uri gem installed for the same Ruby, switching
  `URI_VERSION` can fail with "You have already activated uri". Run
  `bundle update uri` after changing it.
- `Gemfile.lock`, `coverage/`, `docs/superpowers/` and `docs/decisions/` are
  not versioned. The last one holds local design notes.
