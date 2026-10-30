# install.md: LLM installation reference for restless-sdk (Ruby)

This file is the single source of truth for LLM agents installing or configuring the Restless Ruby SDK. Humans should read `README.md` instead.

The document is ordered so an agent can stop as soon as enough context has been loaded: package basics → setup call → where to mount → redaction → settings file → common mistakes.

---

## 1. What this package is

`restless-sdk` captures HTTP request/response pairs and ships them in batches to the Restless ingest server for dashboard display.

- **Runtime:** Ruby 2.6+. **No dependencies.**
- **Shape:** one Rack middleware. Rails, Sinatra, Hanami, Grape, Roda and anything else that speaks Rack all use the same one; there are no per-framework adapters.
- **Install name is not the require name:** you install `restless-sdk` and you `require "restless"`.

## 2. Install

```sh
gem install restless-sdk
```

or in a `Gemfile`:

```ruby
gem "restless-sdk"
```

No other gems are required.

## 3. The one-line setup

Construct a client, register a per-request callback, mount the middleware:

```ruby
require "restless"

CLIENT = Restless.new(ENV["RESTLESS_KEY"])

CLIENT.setup do |request|
  { api_key: CLIENT.mask(request.header("Authorization")),
    owner: { id: workspace_id_for(request), enrich: method(:load_workspace) } }
end
```

The client exposes four things:

| member | purpose |
|---|---|
| `setup(&block)` | Register the per-request callback. Takes a block or any callable. |
| `mask(key)` | Hash an end-user API key for safe logging. |
| `rack` | The middleware factory to mount. |
| `flush` | Upload everything queued and wait for it, retries included (e.g. before exit). |

`Restless.new` and `Restless::Client.new` are the same thing. `mask` is also available as `Restless.mask` without a client, for scripts and tests.

**Construct the client once**, somewhere loaded at boot - `config/application.rb` under Rails, the top of `config.ru` otherwise. Not per request.

## 4. Where to mount it

`CLIENT.rack` returns a middleware factory: anything that calls `.new(app)` on it works.

```ruby
# config.ru - Sinatra, Roda, Hanami, Grape, plain Rack
use CLIENT.rack
run App
```

```ruby
# config/application.rb - Rails
config.middleware.insert_before 0, CLIENT.rack
```

```ruby
# No config.ru at all - wrap where the app is handed to the server
handler = CLIENT.rack.new(APP)
```

**Mount as far OUT as you can.** An inner mount sees a different status and body than the client did.

**Rails: `insert_before 0`, not `use`.** `config.middleware.use` appends to the bottom of the stack, below `ActionDispatch::ShowExceptions`. From there the SDK records the rendered error page rather than the real exception, so a 500 loses its raise site and every crash groups by the wording of your error template.

**The mount is not in the file with the routes.** Rails routes live in `config/routes.rb` and the middleware does not go there. This trips up installers coming from frameworks where the two are the same file.

### Route patterns

The middleware reads the matched route template from the framework, so handlers do not have to report it:

| framework | source | reported as |
|---|---|---|
| Sinatra | `env["sinatra.route"]` (`GET /pets/:id`) | `/pets/{id}` |
| Rails | `env["action_dispatch.route_uri_pattern"]` | `/pets/{id}` |
| Grape | `env["grape.routing_args"]` | as matched |
| anything | `env["restless.route"]`, set by you | as given |

The method prefix is stripped, Rails' `(.:format)` is dropped and `:id`-style params are rewritten to `{id}`, so one endpoint produces the same `routePattern` here as it does in the Node, Python and Go SDKs. Override wholesale with `CLIENT.rack(route: ->(env) { ... })`.

## 5. The setup callback

The callback receives a read-only `RequestInfo` and returns a hash.

| accessor | what |
|---|---|
| `request.header(name)` | One header, case-insensitive. `request["authorization"]` is an alias. |
| `request.request_method` | `"GET"`, `"POST"`, ... |
| `request.path` | `SCRIPT_NAME` + `PATH_INFO`. |
| `request.query_string` | Raw query string, without `?`. |
| `request.url` | Full URL. |
| `request.env` | The raw Rack env, for anything the view does not model. |

Use `header`, not `env["HTTP_AUTHORIZATION"]`.

Result fields:

| field | type | required | notes |
|---|---|---|---|
| `api_key` | `String` or nil | no | Masked key from `CLIENT.mask`. Never plaintext. |
| `owner` | `Hash` | yes\* | The workspace / tenant / end-user this request belongs to. |
| `block` | `true` or `{ status:, message: }` | no | Rejects the request before the handler runs. |

\* Technically optional, but omitting it lands every log in the dashboard as "anonymous".

Extra top-level keys are carried through onto the log.

**The callback runs before your application**, because the middleware is mounted outside everything. `current_user`, Warden, and controller filters have not run yet. Resolve the owner from the credential yourself inside the block.

**A callback that raises is silently ignored.** SAFETY-002 requires that observability never breaks the request path, so an exception is caught and the result discarded. That is correct behaviour, and it means a wrong callback does not crash your app - it just quietly attributes nothing. Verify with §12 rather than assuming.

### 5.1 The `owner` hash

`owner[:id]` is the **permanent, immutable identifier** the dashboard pins a project's entire log history to. Misconfiguring it is the single biggest setup mistake.

| API shape | Use as `id` |
|---|---|
| Multi-tenant SaaS (`Account`, `Organization`, `Workspace`) | The tenant's id |
| Key owned by a project or service (`ApiKey belongs_to :project`) | The project id, not its creator |
| Per-user API (one key per developer) | The user's id |
| No identity model | Omit `owner` entirely |

**Never** an API key, email, username, JWT, or a placeholder literal like `"anonymous"` / `"none"` / `"guest"`. Anything that can rotate, or is a dummy string, is wrong.

For requests with no real owner, omit the key. A Ruby hash literal cannot omit a key conditionally, which is why the idiomatic shape builds the hash and then assigns:

```ruby
CLIENT.setup do |request|
  result = { api_key: CLIENT.mask(request.header("Authorization")) }

  workspace_id = resolve_workspace(request.header("Authorization"))
  if workspace_id
    result[:owner] = { id: workspace_id, enrich: method(:load_workspace) }
  end

  result
end
```

### 5.2 `owner[:enrich]`

The **only** channel for owner metadata. Inline `label` / `email` keys on `owner` are dropped; everything except `id` comes back from `enrich`.

```ruby
enrich: ->(owner_id) {
  workspace = Workspace.find(owner_id)
  { label: workspace.name, email: workspace.admin_emails }   # String or Array
}
```

A lambda or a `method(:name)` reference both work.

Behaviour:

- Cached by `owner[:id]`. The first request from each owner runs it; the rest skip it.
- If an upload comes back with `needsEnrichment`, that owner is invalidated and the next request re-runs it.
- Exceptions are swallowed; the log still ships with the id.
- Skipped entirely when the same result also returns `block`, so a banned tenant does not cost a database round-trip per owner id forever.
- The resolved values ride on every subsequent upload, so each log carries full metadata without re-running the lookup.

## 6. The `mask()` gotcha

`CLIENT.mask(value)` produces `sha512-<base64>?<last4>`. The suffix is the LAST 4 CHARACTERS OF THE INPUT, so substituting a placeholder leaks it.

```ruby
# CORRECT: nil when the header is missing
api_key: CLIENT.mask(request.header("Authorization"))

# WRONG: "mous" ends up as the mask tail
api_key: CLIENT.mask(request.header("Authorization") || "anonymous")
```

`mask` returns nil on nil input and the SDK handles it.

## 7. `.restless/settings.json`

Read at startup, walking up from the working directory. Created and owned by the `restless` CLI (`npx restless init`). Every Restless SDK reads the same file with the same camelCase keys, so a polyglot repo needs only one.

```json
{
  "version": 1,
  "apis": [
    {
      "id": "<api uuid>",
      "name": "Public API",
      "rootDir": ".",
      "projectId": "<restless project uuid>",
      "oasFile": ".restless/openapi.yaml",
      "framework": "rails",
      "language": "ruby",
      "baseUrl": "https://api.example.com",
      "requestIdPrefix": "PUB",
      "redact": { "headers": ["x-company-auth"], "bodyKeys": ["ssh_private_key"] },
      "sampling": { "default": "on", "routes": { "GET /health": "off", "GET /pets": 0.1 } }
    }
  ]
}
```

The SDK reads `requestIdPrefix`, `redact` and `sampling` (§8a, merged with the `sampling:` option, code winning per route) from the matching entry. The rest, `projectId` included - which is per-API and never top-level - belongs to the CLI, not the runtime. Pick one when several are defined:

```ruby
Restless.new(ENV["RESTLESS_KEY"], api: "Public API")
```

## 8. Redaction (on by default)

Sensitive values are redacted BEFORE anything leaves the process.

- **Headers:** `authorization`, `cookie`, `set-cookie`, `proxy-authorization`, `x-api-key`, `x-auth-token`
- **Body keys and query params:** `password`, `pass`, `pwd`, `token`, `secret`, `apikey`, `accesstoken`, `refreshtoken`, `idtoken`, `sessionid`, `ssn`, `creditcard`, `ccnumber`, `cvv`, `cvc`

Matching is case-insensitive and ignores `-`/`_`, so `api_key` / `apiKey` / `API-KEY` all match. For `authorization` and `proxy-authorization` the scheme word survives (`Bearer <REDACTED:...>`).

Two additive sources on top of the defaults: `apis[].redact` in the settings file, and the `redact:` option. **The option accepts either casing**, so `body_keys:` and `bodyKeys` both work - snake_case reads better in Ruby, camelCase matches the wire format:

```ruby
Restless.new(key, redact: { headers: ["x-custom"], body_keys: ["api_secret"] })
```

Sentinel format, which the dashboard pattern-matches:

```
<REDACTED:<length>>                 # length < 8
<REDACTED:<length>:<last-4-chars>>  # length >= 8
```

Bodies are capped at **256 KiB** (UTF-8 bytes) and truncated with `[...TRUNCATED: original N bytes]`.

## 8a. Sampling (off by default)

Without a `sampling` block every request is logged in full. With one, each endpoint gets a mode:

| mode | successes (< 400) | errors (>= 400) |
|---|---|---|
| `"on"` (default) | full log | full log |
| a rate `0` to `1` | that fraction in full, the rest without bodies | full log |
| `"errors"` | nothing sent | full log |
| `"off"` | nothing sent | nothing sent |

```ruby
Restless.new(ENV["RESTLESS_KEY"], sampling: {
  routes: { "GET /health" => "off", "GET /pets" => 0.1, "* /internal/{job}" => "errors" },
})
```

Rules an installer should know:

- Keys are `"<METHOD> <route pattern>"`, with `*` for any method. Use the pattern the framework matched (`/pets/{id}` or `/pets/:id`, both work; §4 "Route patterns"), never a concrete URL like `/pets/42`. `HEAD` does not fall back to `GET`. A request with no route pattern uses `default`.
- Modes are the strings `"on"`, `"off"`, `"errors"` (symbols work in code), or a number from 0 to 1. Anything else falls back to `"on"`; it never raises.
- Only suggest `"off"` or `"errors"` for endpoints the user agrees are noise (health checks, readiness probes, polling). Never sample auth or payment endpoints without asking.
- A request that sends nothing also gets no `x-request-id`, `x-debug` or `x-api-feedback` header, so do not use an `"off"` route to verify the install (§13).

## 9. Request IDs and response injection

- Request IDs are v4 UUIDs, never time-based, so they leak no ordering.
- The SDK sets exactly one id header, always its own: `x-request-id` by default, or `x-restless-id` when the incoming request already carried an `x-request-id` (we never stomp or reuse an existing chain). With no key resolved the value is the literal `missing-key`.
- On **every** status the SDK adds `x-log-url: <portalOrigin>/logs/<id>`, `x-debug: npx api debug <id>` and `x-api-feedback: npx api feedback <id>` headers; on status **>= 400** it also merges a `debug` key into a JSON body. There is no user-configurable hook for this. The one exception is a request that sampling drops (§8a): it gets no id header and nothing injected.
- `x-log-url` points at your project's public docs host, which the server tells the SDK on each upload. Until the first upload round-trips it is omitted rather than guessed: a URL that 404s is worse than no URL. The ingest host is never used for it. `x-debug` and `x-api-feedback` carry no URL, so they are present from the very first response.
- Browser callers only see these headers if the API lists them in `Access-Control-Expose-Headers` (for example `x-log-url, x-debug, x-api-feedback`); same-origin and server-side callers see them without it.

## 10. Blocking

```ruby
CLIENT.setup do |request|
  next { block: true } if banned?(request)                              # 403
  next { block: { status: 429, message: "slow down" } } if limited?(request)

  { api_key: CLIENT.mask(request.header("Authorization")) }
end
```

The handler never runs. The response body is JSON `{"error": "<message>"}`. `enrich` is not called for a blocked request. Sampling (§8a) treats a blocked request like any other response with its status: a 403 or 429 is logged in full, except on an `"off"` route, where it is not logged and gets no id header.

## 11. Environment variables and batching

| variable | effect |
|---|---|
| `RESTLESS_KEY` | Fallback API key when `Restless.new` is called without one |
| `README_API_KEY` | Secondary fallback |
| `RESTLESS_BASE_URL` | Override the ingest URL. **Non-localhost `http://` warns loudly** (plaintext auth). |
| `DEBUG=restless` | Print upload diagnostics to stderr |
| `RESTLESS_SETUP_MODE=1` | Upload even under a test runner (see below) |

Batching is fixed, with no config:

- 10 requests per batch, a 5000 ms flush interval, and immediate flushing outside production or against a localhost base URL
- A 1000-entry queue that drops oldest on overflow
- At most 4 uploads in flight; while capped, each freed slot sends up to 100 queued entries
- Upload timeout: 10 s
- Retries: only `503`/`429` (honouring `Retry-After`, max 2 retries, max 10 s wait) and connections that never reached the ingest (refused, DNS failure). Never `502`/`504`, timeouts or dropped connections, which the ingest may already have stored.
- Safe under forking servers (Puma, Unicorn): a forked worker starts with an empty queue and its own uploads.

Uploads run on background threads and never block a response. Failures are swallowed unless `DEBUG=restless`. There is nothing to configure here and nothing to add to the user's code.

**Test runs do not upload.** Detected via `RAILS_ENV`/`RACK_ENV` of `test`, or RSpec / Minitest / Test::Unit being loaded. Capture still runs, so your tests exercise the real path.

## 12. Common mistakes (don't do these)

- **Mounting with `config.middleware.use` in Rails.** That appends to the bottom of the stack, below `ShowExceptions`, so the SDK sees a rendered error page instead of the exception. Use `insert_before 0`.
- **Adding a `before_action` instead of middleware.** It runs far too late and only for requests that reach a controller, so every 404 and every rejected request goes unrecorded.
- **Editing `config/routes.rb`.** The middleware does not go there.
- **Reading `current_user` in the callback.** The middleware is outside the stack, so it has not been set yet. Resolve the owner from the credential.
- **`CLIENT.mask(header || "anonymous")`** - see §6.
- **Using an API key, email, username or JWT as `owner[:id]`** - see §5.1.
- **Inline `label` / `email` on `owner`** - dropped. They come back from `enrich`.
- **Constructing a client per request.** Once, at boot.
- **Reading `.env`, `config/master.key` or `config/credentials.yml.enc` to "check" the key.** LLMs: never read these.
- **`gem install restless`** - the gem is `restless-sdk`. `restless` is only the require name.
- **Looking for `restless/rails` or `restless/sinatra`.** There is one Rack middleware.

## 13. Quick verification after installation

1. `restless-sdk` appears in the `Gemfile`, and `bundle list` finds it.
2. `CLIENT.rack` is mounted in `config.ru` or `config/application.rb`, as far out as possible.
3. A `CLIENT.setup` block exists and reads its header via `request.header(...)`.
4. `.restless/settings.json` exists (created by `npx restless init`).
5. Starting the server and curling any endpoint returns an `x-request-id` response header carrying a fresh id - `<prefix>-<uuid>` when the API has a `requestIdPrefix` in `.restless/settings.json` (the CLI sets one on every project), otherwise a bare UUID. If your curl sends its own `x-request-id`, look for `x-restless-id` instead. Plenty of stacks set `x-request-id` themselves, so the unambiguous proof it came through our SDK is the `x-debug` header, which rides every captured response. A value of `missing-key` means the server is up but never loaded `RESTLESS_KEY`; restart it.
