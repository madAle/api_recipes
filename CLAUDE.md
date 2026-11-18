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
bundle exec ruby -Ilib exe/api_recipes upgrade                                  # in the root of a project: finds code and configuration by itself
bundle exec ruby -Ilib exe/api_recipes upgrade app lib --config config/apis/github.yml
bundle exec ruby -Ilib exe/api_recipes import spec/fixtures/openapi/github_small.yml --name github
bundle exec ruby -Ilib exe/api_recipes routes spec/fixtures/openapi/github_small.expected.yml
bundle exec ruby -Ilib exe/api_recipes routes                                   # in the root of a project: every api it has
bundle exec ruby -Ilib exe/api_recipes check path/to/NAME.recipe.yml   # a portable recipe
bundle exec ruby -Ilib exe/api_recipes convert config/apis/github.yml   # from a file of a project to a portable recipe
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
| `lib/api_recipes/internals/definition.rb` | the immutable tree that `definition` returns |
| `lib/api_recipes/internals/compiler.rb` | turns the configuration into a tree and validates it; reports every problem at once; expands `resource` into endpoints |
| `lib/api_recipes/internals/path_template.rb`, `template.rb` | the `path` of an endpoint, and `{variable}` strings, with their encoding rules |
| `lib/api_recipes/internals/option_value.rb` | the options of a request written with `{variables}` (`protocol`, `port`, `timeout`, `on_bad_code`, `mime_type`, `verb`, `ok_code`): made when the request is built, checked for the option |
| `lib/api_recipes/internals/handles.rb` | generates the subclasses of `Api` and `Endpoint` with one method per child |
| `lib/api_recipes/internals/context.rb` | which tree, which owner and which `with` options a chain uses; resolves values |
| `lib/api_recipes/internals/level.rb`, `credential.rb` | credentials and variables assigned to the module, a class or an object |
| `lib/api_recipes/internals/plain_yaml.rb` | reads YAML that is only data: no anchors, aliases, tags, merge keys, repeated keys; used for recipes and locks |
| `lib/api_recipes/internals/recipe.rb`, `recipe_lock.rb` | a portable recipe (`NAME.recipe.yml`) with the rules of its format, and the `recipes.lock` of its folder |
| `lib/api_recipes/internals/registry.rb` | what `configure` produced, swapped in at once; the global apis |
| `lib/api_recipes/internals/declaration.rb` | one `api :name` in a class or a module |
| `lib/api_recipes/internals/request.rb` | builds the URL and the http.rb client, sends the request, checks the outcome |
| `lib/api_recipes/cli.rb`, `cli/upgrade.rb`, `exe/api_recipes` | the `api_recipes` command and its `upgrade` checks |
| `lib/api_recipes/cli/upgrade/screen.rb` | how `upgrade` shows its results: the same sections everywhere, and colours, marks and lines that fit on a terminal |
| `lib/api_recipes/cli/upgrade/project.rb` | what `upgrade` without arguments finds in a project: Ruby files, descriptions of apis, the names of the apis |
| `lib/api_recipes/cli/import.rb` | the `import` command: from an OpenAPI description to the text of a recipe, checked before it is returned |
| `lib/api_recipes/cli/import/document.rb` | reads the description (YAML or JSON) and follows its internal `$ref` |
| `lib/api_recipes/cli/import/server.rb`, `security.rb` | the address, the variables and the `auth` of the api |
| `lib/api_recipes/cli/import/tree.rb` | from the paths to the tree of endpoints: names, operations, comments, warnings |
| `lib/api_recipes/cli/import/writer.rb` | writes the YAML with the comments and reads it back |
| `lib/api_recipes/cli/routes.rb` | the `routes` command: the calls of the files it is given, or of every api of the project |
| `lib/api_recipes/cli/calls.rb` | how each endpoint of a compiled api is called in Ruby: what `import --calls` and `convert --calls` write in the comments |
| `lib/api_recipes/cli/tags.rb` | the ERB tags of a file that is read without running it: each output tag replaced by a mark |
| `lib/api_recipes/cli/code.rb` | the code a command gives to paste: how it is shown, in colours on a terminal, and the block of `ApiRecipes.configure` of a file |
| `lib/api_recipes/cli/convert.rb` | the `convert` command: from a configuration file of a project to the text of a portable recipe |
| `lib/api_recipes/cli/convert/migration.rb` | what `convert` changes in a project: the installed recipe, `config.values` in the file that calls `configure`, the old description |
| `lib/api_recipes/cli/recipes.rb` | the `install`, `update` and `check` commands for portable recipes |
| `lib/api_recipes/cli/recipes/git.rb` | reads one file from a Git repository: no working copy, no shell, `https` and `ssh` only |
| `lib/api_recipes/cli/recipes/summary.rb`, `lock_file.rb` | what `install` and `update` show; the text of `recipes.lock` |
| `spec/fixtures/openapi` | OpenAPI descriptions for the specs; `SOURCE.md` says where the real one comes from |
| `spec/unit`, `spec/integration` | specs; integration specs stub HTTP with WebMock |
| `spec/security` | one example per protection, and `README.md` that maps them |
| `spec/docs/examples_spec.rb` | evaluates the examples of README.md and UPGRADING.md |
| `spec/support/test_apis.rb` | shared configuration and helpers for specs |
| `spec/support/recipe_helpers.rb` | helpers for portable recipes, and a Git repository in a temporary folder |
| `spec/fixtures` | YAML files for configuration specs |
| `examples` | runnable scripts that call public APIs |
| `README.md`, `UPGRADING.md` | the user guide, and the guide for people coming from 2.x |
| `docs/ROADMAP.md` | what the next versions contain |

## How a call works

1. `ApiRecipes.configure` loads the sources, then the portable recipes of
   `recipes_paths` (each checked against its `recipes.lock`), compiles them into
   one immutable tree per api and validates them. Only if that succeeds is the new registry swapped
   in, together with one method per api on the `ApiRecipes` module. `api :name`
   in a class or a module defines the same method on it and on its instances.
2. That method returns an `Api`. Each endpoint method returns a new `Endpoint`
   that knows its node of the tree and its path, built from the parent path, its
   own `path`, the arguments and the variables that the `path` uses. `[]` does the same by name, and the generated
   methods call it.
3. Credentials and variables are not kept on these objects. They live in levels
   and are read, nearest first, when the request is built: the object that
   makes the call, the class or module that declared the api, the whole
   application. `with` adds a level for one chain. The last two are shared by
   every thread, so only the place where the application starts gives them:
   `config.values` for the application, kept in the registry that `configure`
   swaps in together with the trees; the options of `api` for a class, kept in
   its `Declaration`. Only the level of an object is stored on its owner
   (`LevelSet`). The writers of `Api` work on an object and raise on a class,
   a module and `ApiRecipes.name`.
4. `run`, or a block, creates a `Internals::Request`, which builds the URL and the http.rb
   client with the default headers and parameters of the api, of `with` and of
   the endpoint, sends the request, checks the outcome (`ok_code`, `on_bad_code`,
   `verify_with`) and returns a `Response`.

Objects of the chain are created again at every step. The tree and the generated
classes are built once, by `configure`.

## Rules for changes

- Specs never use the network: `WebMock.disable_net_connect!` stays on.
- A spec for existing behaviour must pass without touching `lib/`.
- A behaviour change comes with its spec, written first.
- Internal classes live under `ApiRecipes::Internals`, so that `include ApiRecipes` does not shadow an application's own constants. Only `Api`, `Endpoint`, `Response`, `Configuration`, the errors and `VERSION` stay directly under `ApiRecipes`.
- Ruby 3.3 syntax; the block parameter `it` is not allowed (Ruby 3.4).
- The code of the commands lives under `ApiRecipes::CLI`, uses only the standard library and is not loaded by `require 'api_recipes'`. `api_recipes import` opens one file, never uses the network, and never turns a mapping or a list of the description into text: every value read from the description goes through `Import.text`, `Import.shown` or `Import.one_line`, never through `to_s` or an interpolation. With YAML aliases a small file can describe a huge structure; `Document::Shape` refuses the largest ones while the text is parsed.
- `api_recipes convert`, and `api_recipes upgrade` and `api_recipes routes`
  without `--erb`, never run the ERB of a file: a tag is replaced by a token
  before the text is parsed (`Tags.replaced`).
  `convert` has no option that evaluates ERB, because its result is meant for a
  shared repository: a header or a parameter that `Convert::CREDENTIAL` matches
  is written as a variable, never with its value or with a default. The
  messages of the command hold names, shown with `Recipes::Summary.shown`. The
  code to paste that it prints when it does not change the project
  (`Convert::Snippet`) is the one exception, decided by the maintainer: it
  holds the code of the tags and the values written in the file, so that it
  works when pasted, and leaves out only what `Code::UNSAFE` matches. The code
  that `upgrade` gives to paste follows the same decision: it holds what a
  line assigned, never a line as it is, only whole Ruby expressions, and
  `--no-code` leaves it out.
  The mark that stands for a tag is random, so that no file can write one.
  The recipe is checked with `Internals::Recipe` before it is written, and the
  file is created with `File::EXCL`.
- `Convert::Migration` is the only code of the gem that edits or deletes a
  file of a project. It reads Ruby as a tree (`Code.tree`, Prism, a default
  gem), never with a regular expression on lines, and never runs it. It works
  out every change in memory, each on the text the changes before it left,
  writes none when one is not possible or when a result is not valid Ruby, and
  puts every file back when a write fails. It adds lines only to a plain file
  that git tracks (`H` in `git ls-files -v`, and present in `HEAD`), and
  deletes a file or takes lines out of it only when git has it committed as
  it is now. It edits only the shapes it reads whole, listed in the README:
  a new shape is refused, with the code to paste, never guessed. `git` is run
  with `Migration::GIT`, so that it runs no program the repository names. When it changes the project it prints nothing of
  what the file holds; when it does not, it prints the steps and the code to
  paste.
- A portable recipe is written by someone else. A file of `recipes_paths`, and
  what `install`, `update` and `check` read, is read only by
  `Internals::Recipe`: never with ERB, never with `YAML.safe_load` directly, and
  the lock is compared before the file is parsed. Whatever comes from a recipe
  or from a repository reaches the terminal through `Recipes::Summary.shown`.
  `git` is run without a shell, with the options of `Recipes::Git#transport`,
  and only after `Git.address_problem`: `https` without a user, or `ssh`
  (`ssh://` and `user@host:path`) with a user, a host and a path that never
  start with a hyphen. The specs reach a repository through `file://` because
  `with_recipe_repository` replaces `Git::PROTOCOLS`: nothing in `lib/` may
  accept another protocol. No spec starts `ssh`.
- In a spec, write an invisible character as an escape (`"\u202E"`), never as
  the character itself.
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
- Nothing writes the level of the application or of a class after the
  application has started: no writer, no method that a request could call.
  A value that changes from one request to the next belongs to `with` or to an
  object. A request reads the registry once and takes the tree and the values
  of the application from it: do not read `Registry.current` twice for one
  request. Values of variables are kept as frozen text.
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
