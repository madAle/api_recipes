# 0004 Scope of credentials

**Status:** Accepted, for 3.0

## Decision

`authorization` and `basic_auth` are looked up along a chain: the instance, then
its class, then the global api.

- Set on the global api (`ApiRecipes.github`): the default for everyone.
- Set on a class (`MyClass.github`): the class, its instances and its subclasses.
- Set on an instance (`client.github`): that instance only.

A level without a value of its own uses the next one.

## Why

The case to get right is one client object per user:

```ruby
class GithubClient
  include ApiRecipes
  api :github

  def initialize(token)
    github.authorization = token
  end
end
```

| Option | Two clients with different tokens | Token set once for a class |
| --- | --- | --- |
| Chain: instance, class, global | each keeps its own | works |
| One value per class, shared with instances | the second overwrites the first | works |
| Global only (2.x) | not possible | not possible; use `default_headers` |

With a shared value, a request can be sent with the token of another user. The
chain makes one object per user safe without any new method.

## Consequences

- An instance that sets its credentials must be kept: a value set on an instance
  does not reach other instances.
- Credentials on a class or on the global api are still shared by every thread.
  They are meant to be set once, when the application starts.
- A token for a single request stays possible with the `headers:` option.
- The library stores a value per instance, so it must not keep instances alive
  after the application drops them.
