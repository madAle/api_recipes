# Security specs

Every protection of section 5 of the 3.0 design has an example in this folder
that proves the abuse case through the public DSL: the example does what an
attacker (a user typing a value, a server answering, a file on disk) would do,
and fails when the protection is removed. Run them with
`bundle exec rspec spec/security`.

Section 5.6 (shared recipes) and 5.7 (OpenAPI importer) belong to later
releases and are not in the tables. Where a row below depends on them, it says so.

Spec files:

| File | What it covers |
| --- | --- |
| `url_injection_spec.rb` | values typed at run time: path parameters, variables, `with(host:)`, headers |
| `dsl_credentials_spec.rb` | credentials through the DSL: owners, `with`, origins, restored and frozen objects |
| `credentials_spec.rb` | the same rules on the request layer, with explicit levels |
| `declarations_spec.rb` | one api declared through modules, subclasses, `extend` and singleton classes |
| `redirects_spec.rb` | redirects on the request layer |
| `dsl_responses_spec.rb` | redirects, `fill`, `data` and timeout through the DSL |
| `fill_spec.rb` | `Response#fill` with keys chosen by the server |
| `dsl_objects_spec.rb` | what `Api`, `Endpoint` and `Response` show, write and let Ruby do |
| `dsl_logging_spec.rb` | what the logger receives |
| `configuration_spec.rb` | local files, ERB, YAML, refused configurations |

## 5.2 Values put in the URL and in the headers

| Risk | Protection | Spec | Example |
| --- | --- | --- | --- |
| A parameter with `/`, `..` or `?` reaches another endpoint | each value is one encoded segment | `url_injection_spec.rb` | `keeps the path parameter ... inside its segment` (one per hostile value), `sends a slash of a path parameter as %2F and keeps the segment count` |
| A path parameter that is `nil`, empty, `.` or `..` | refused, not neutralized | `url_injection_spec.rb` | `refuses, and does not neutralize, the values that name no segment or the current or parent one` |
| A `*name` placeholder used to climb | each piece encoded; empty, `.`, `..` pieces refused | `url_injection_spec.rb` | `rejects the splat value ...`, `rejects the splat value ... that has an empty, current or parent piece`, `encodes each piece of a splat value` |
| A variable in the host name moves the request to another server | restricted character set for the host position | `url_injection_spec.rb` | `rejects the host variable ...` |
| A variable in `base_url` climbs or leaves its segment | the value is one encoded segment | `url_injection_spec.rb` | `keeps a base_url variable inside its segment` |
| `with(host: ...)` or `api :x, host: ...` with a malformed value | same validation as the `host` of the configuration | `url_injection_spec.rb` | `rejects the host ... in with and in api`, `refuses a protocol or a port that is not one in with and in api` |
| A value adds a header (`default_headers`) | line breaks and control characters refused | `url_injection_spec.rb` | `refuses a header value that would add a header` |
| A variable used in a header adds a header | line breaks and control characters refused in variables | `url_injection_spec.rb` | `refuses a variable that adds a header through default_headers` |
| A credential with a line break adds a header | refused by the gem before http.rb sees it | `dsl_credentials_spec.rb` | `a credential with a control character is refused before it is sent, without showing it` |
| The form of a host is checked, not its owner | stated limit of the gem | `url_injection_spec.rb` | `does not decide whose a well-formed host is` |

## 5.3 Credentials

| Risk | Protection | Spec | Example |
| --- | --- | --- | --- |
| The token of one user used for the request of another | chain instance, class, global; `with` keeps nothing | `dsl_credentials_spec.rb`, `credentials_spec.rb` | `does not use the token of one object for the request of another`, `lets an instance with no token of its own take the shared one, and never the token of a sibling`, `keeps nothing from with`, `refuses to store a credential on an object returned by with`; `gives each object its own token`, `walks instance, class, global` |
| A client with no token acts with the shared one | an assignment closes the lookup, also `nil` | `dsl_credentials_spec.rb`, `credentials_spec.rb` | `sends no token for a client whose token was set to nil, although a shared one exists`; `stops at an explicit nil instead of using the shared token` |
| A shared token sent to a different host | a credential is valid for the origin of the level that set it | `dsl_credentials_spec.rb`, `credentials_spec.rb` | `does not send a shared token to another host, protocol or port selected with with`, `does not send a token to a host a variable selects, when the token was set at a farther level`, `does not send a token whose own level cannot tell the host a variable selects`, `does not let a class that changes the host receive the global token`, `sends a token set together with the destination, and only to it`; `does not send a token to an origin it was not set for`, `does not send a token over another scheme`, `binds a token to the host a variable selects`, `binds a superclass token to the host the superclass selects, not a subclass variable` |
| A second declaration of an api sends a token elsewhere | an api is declared once per class hierarchy, also across modules | `declarations_spec.rb` | `refuses an object extended with a module that declares the api of its class again`, `refuses a subclass that includes a module declaring the api of its superclass`, `refuses an object extended with two modules that declare the same api`, `refuses a declaration on a singleton class`, `does not send the global credential to the host of a class tree` |
| An object restored from a serialized form acts with a credential | the container never writes its value; a restored one means "no credential" | `dsl_credentials_spec.rb` | `sends no credential after a Marshal round trip`, `sends no credential after a YAML round trip`, `sends a restored credential container as no credential, whatever the form` |
| A frozen client object | assignment refused, `with` still works, nothing shared | `dsl_credentials_spec.rb` | `refuses to store a credential on a frozen object, which can still send one with with` |
| A credential in a log | no query string, header or body in any line, secrets in every place | `dsl_logging_spec.rb` | `puts no secret in the debug lines and in the printed urls` (header, query and default auth), `puts no secret in the debug lines for a basic_auth credential`, `puts no secret in the log of a request that fails`, `puts no secret in the log when the configuration is refused`, `puts no value in the upgrade warnings, and nothing about the request` |
| A credential in `inspect`, `to_s`, `pp` or `definition` | dedicated `inspect` on every object; `definition` holds none | `dsl_objects_spec.rb`, `configuration_spec.rb` | `shows no option, header, credential or query whatever way they are printed`, `holds no credential in the definition, whatever way it is read`, `does not let an endpoint named inspect hide the safe inspect`; `never shows a credential, whatever is inspected` |
| A credential written when the owning object is serialized | `Api`, `Endpoint` and `Response` refuse every serialization | `dsl_objects_spec.rb` | `refuses every serialization of an Api and of an Endpoint`, `refuses serialization, because the http.rb response holds the request with the credential` |
| A credential in an error message | the value never enters a message | `dsl_credentials_spec.rb`, `configuration_spec.rb`, `dsl_objects_spec.rb` | `a credential with a control character is refused before it is sent, without showing it`; `does not put a credential with a line break in an error`; `an error about the response carries no credential, query, header or body in its message` |
| A credential in the query ends up in `url` | `url` never has a query string; the parameter is added when the request is sent | `dsl_objects_spec.rb` | `keeps the credential sent in the query out of url, and adds it only when the request is sent` |
| A credential in the query visible from `response.uri` or the request | `uri` omits it; `Response` does not expose the request | `dsl_objects_spec.rb` | `a response omits the credential sent in the query from uri`, `a response does not expose the request and does not show it in inspect` |
| A response body with personal data in the error message | the body stays on `error.response` | `dsl_objects_spec.rb` | `an error about the response carries no credential, query, header or body in its message` |
| A redirect forwards the credential to another server | no redirect unless asked; with `follow`, `Authorization`, the header named by `auth`, `Cookie` and a query credential are dropped when the origin changes and not given back | `dsl_responses_spec.rb`, `redirects_spec.rb` | `a redirect is not followed unless the request asks for it`, `does not take the credential, the header named by auth or the cookie to another origin`, `does not take the header named by auth to another origin, nor give it back on the way home`, `does not take a credential sent in the query to another origin`; `drops the credential and the cookies when the redirect leaves the origin`, `drops the header named by auth`, `drops the credential when only the scheme or only the port changes`, `does not give the credential back after a redirect out of the origin and back`, `does not carry cookies along the chain, whoever set them`, `does not repeat a credential sent in the query to another origin` |
| A `follow` value that http.rb would take as it is | only `true`, `false`, `nil` or a Hash of `strict`, `max_hops`, `on_redirect`, checked before sending | `dsl_responses_spec.rb`, `redirects_spec.rb` | `a redirect refuses a follow value that http.rb would take, before anything is sent`; `refuses any follow value other than true, false, nil or a Hash, with or without a credential`, `refuses follow options that http.rb would refuse, before sending anything` |

## 5.4 Answers of the servers

| Risk | Protection | Spec | Example |
| --- | --- | --- | --- |
| `fill` calls a setter chosen by the server (`admin=`, a private method) | public writers only, keys that are plain attribute names, `only:` and `except:` in any form | `dsl_responses_spec.rb`, `fill_spec.rb` | `fill calls only the public writers that match a plain attribute name`, `fill limits a list of objects with only and except, in every form`, `fill ignores what is not an object or a list of objects`; `never calls a private writer`, `skips keys that are not plain attribute names`, `only and except given in different forms` |
| An answer that never arrives | `timeout` always set, 3 seconds by default; a value that would remove the limit is refused | `dsl_responses_spec.rb` | `sets a timeout of 3 seconds on every request, and no request has none`, `refuses a timeout that would remove the limit, and nil falls back to the default` |
| A body read as Ruby objects | `data` uses only the http.rb parser of the declared type | `dsl_responses_spec.rb` | `data never builds Ruby objects from a body`, `data does not read a type that http.rb has no parser for, and so never reads YAML`, `data does not read YAML even when the type is forced with mime_type` |
| An implicit conversion (`to_ary`, `to_str`, `encode_with`, ...) changes what Ruby does with an object | no method is generated for these names; the endpoint stays reachable with `[]` | `dsl_objects_spec.rb` | `does not change how Ruby treats the parent of an endpoint named after an implicit conversion`, `still reaches an endpoint with such a name with [] and sends its request` |

## 5.5 Local configuration

| Point | Protection | Spec | Example |
| --- | --- | --- | --- |
| ERB is code: evaluated only for the files of `apis_files_paths` | no ERB anywhere else | `configuration_spec.rb` | `evaluates ERB in the files of apis_files_paths and nowhere else`, `never evaluates ERB found in a value of apis_configs or in a response` |
| YAML is always read safely | `YAML.safe_load`, no Ruby objects | `configuration_spec.rb` | `does not build Ruby objects from YAML`, `reads YAML anchors and aliases without building objects, and refuses other tags`, `refuses a file that is not a mapping, is empty or is not UTF-8, without showing its content` |
| `verify_with` calls a method, even a private one, of the calling object | allowed only in local sources, `api` and `with`; never in shared recipes | `configuration_spec.rb` | `lets verify_with call a private method of the calling object, given in api or in with`. The shared-recipe half belongs to 5.6, a later release |
| A `*.recipe.yml` passed to `apis_files_paths` | refused, whatever the case or the link, and its ERB is not run | `configuration_spec.rb` | `refuses a file named *.recipe.yml in apis_files_paths, whatever the case and the link, and does not run its ERB` |

Also covered, and not a row of the design: a configuration that is refused
before anything is built (a Hash that contains itself, a YAML alias to its own
mapping, an option given as a String and as a Symbol, names that are empty or
have control characters or invalid encoding, a placeholder in `base_url`, a
host with a character a host cannot have), and the previous configuration
being kept (`configuration_spec.rb`, `a configuration that is refused before
anything is built`).

## What the gem does not do

The application must:

- Not pass to `with(host:)`, or to a variable that is the whole host, a value
  chosen by an end user. The gem checks the form of a host name (letters,
  digits, `-`, `_`, `.`), not whom it belongs to. A request to a well-formed
  host chosen by an attacker is sent, and the credential is not sent to it only
  if it was set for another origin (`does not decide whose a well-formed host is`).
- Treat `original_response` as sensitive: it holds the request, with a
  credential sent in the query.
- Keep `follow` off for requests it does not need to follow, and not give
  `on_redirect` a hook that sends the credentials elsewhere.
- Protect its own configuration files: ERB in `apis_files_paths` runs as code.
- Treat every value of a response as untrusted: `fill` writes the public
  attributes that match a key, so `only:` is the list of attributes a server may set.
- Decide how long a credential lives and where it is stored: the gem keeps it in
  memory, per object, and never writes it.
