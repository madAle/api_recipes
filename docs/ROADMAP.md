# Roadmap

What each planned release contains. Design choices are explained in
[decisions](decisions).

## 2.10.4: maintenance

Ready on `feature/test-foundation`. No behaviour change for existing code.

- `logger` is a declared dependency. From Ruby 4.0 it is no longer a default gem.
- `ApiRecipes.reset!` clears the global configuration and apis, for test suites.
- The gem metadata links the changelog and the source code.
- The README is a complete usage guide.
- The test suite runs without network and on CI.

## 3.0: fixes that change behaviour

Status: proposed, scope to be confirmed. Each item is a known defect of the 2.x
line. Specs must not pin the present behaviour of these.

| Area | Today | In 3.0 |
| --- | --- | --- |
| Errors | inherit from `Exception`; a bare `rescue` does not catch them | one base class `ApiRecipes::Error < StandardError` |
| Path parameters | inserted as given: `/` spans two segments, `nil` builds the parent URL, a `:` in a value breaks nested endpoints, `/:name.json` loses the suffix | URL encoded per segment; `nil`, empty, `.` and `..` raise |
| Credentials | set on a class api they are lost; set on the global api they are shared by every thread | see [decision 0004](decisions/0004-credentials-scope.md) |
| Configuration | unknown options and unknown `on_bad_code` values are accepted silently; `verb` is not checked | validated when the api is configured |
| Api and endpoint names | a name equal to an existing method is skipped silently or replaces that method | reported when the api is configured |
| `verify_with` errors | the message contains the response body | the body stays on `error.response` only |
| `Response` | `respond_to?` is false for the methods it forwards | `respond_to_missing?` implemented |
| `Route#fill` | every error raised by a setter is swallowed | only missing writers are skipped |
| YAML files | a missing or empty file fails without context | a clear `ApiRecipes` error naming the file |
| Core extensions | methods added to `Hash` and `Array`; `URI::DEFAULT_PARSER` replaced with uri < 1.0 | no monkey patches |
| Logging | STDOUT at debug level by default; `print_urls` uses `puts` | silent by default; URLs go to the logger |
| Dead code | unused public methods, constants and four error classes | removed |
| Ruby | `required_ruby_version >= 2.7.0` | the oldest maintained version |

## 3.x: features

Additions that do not break existing code.

- Endpoint tree built once and a reused http.rb client, with persistent connections.
- Retries, and separate connect and read timeouts.
- Hooks to instrument requests.
- A way to reach an endpoint whose name equals an existing method.
- RuboCop, introduced when no feature branch is open.
