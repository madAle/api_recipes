## Unreleased - uri 1.x and Ruby 3.4

- `Hash#transform_keys` and `#transform_keys!` are no longer redefined: Ruby's own are
  used. The replacements broke Hash subclasses whose constructor needs arguments (e.g.
  `Dotenv::Environment` in dotenv 3) and the hash argument added in Ruby 3.0.
- Works with the uri gem 1.x: the patch that lets hostnames contain underscores is
  applied only to the RFC 2396 parser of uri < 1.0, since the RFC 3986 parser of
  uri 1.x accepts them already. Requiring api_recipes with uri 1.x raised
  `ArgumentError`.
- Allows http up to 5.x (was `<= 5.1`). http 5.1.0 requires base64 without declaring
  it, so api_recipes failed to load on Ruby 3.4.

## Version 2.10.1

**SYNTAX COMPLETELY CHANGED**

#### A lot of new stuff

## Version 0.6.0 - Default to HTTPS

**POSSIBLE BREAKING CHANGES**

Requests now default to HTTPS. If you still want to use (unsecure) HTTP you have to specify it in your configs through the dedicated `protocol` option e.g.

```yaml
github:
  protocol: http
  host: api.github.com
```

## Version 0.5.0 - Better Exceptions

Exceptions now include attributes that can be accessed during the `rescue` phase in order to execute specific actions
