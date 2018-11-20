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
