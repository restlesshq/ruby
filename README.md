# restless-sdk

Capture your API traffic and send it to [Restless](https://restless.ai).

One Rack middleware covers **Rails**, **Sinatra**, **Hanami**, **Grape**,
**Roda** and anything else that speaks Rack. Ruby 2.6+. No dependencies.

## Install

```sh
gem install restless-sdk
```

or in a `Gemfile`:

```ruby
gem "restless-sdk"
```

## Use

```ruby
require "restless"

CLIENT = Restless.new(ENV["RESTLESS_KEY"])

CLIENT.setup do |request|
  {
    api_key: CLIENT.mask(request.header("Authorization")),
    owner: {
      # Permanent and immutable. A workspace id or database primary key,
      # never an API key, email, or anything else that rotates: the
      # dashboard pins a project's whole log history to this.
      id: workspace_id_for(request),
      # Runs once per owner id, then caches for an hour. Put the expensive
      # lookup here, not in the fields above.
      enrich: ->(owner_id) {
        workspace = Workspace.find(owner_id)
        { label: workspace.name, email: workspace.admin_emails }
      },
    },
  }
end
```

Then mount it.

```ruby
# config.ru (Sinatra, Roda, Hanami, plain Rack)
use CLIENT.rack
run App

# config/application.rb (Rails)
config.middleware.insert_before 0, CLIENT.rack
```

`CLIENT.rack` returns a middleware factory: anything that calls `.new(app)`
on it works. Mount it as far **out** as you can, so it sees the real status
and body your app produced rather than an inner layer's.

## What you get

- **Lazy owner enrichment.** The `enrich` callback runs on the first request
  from each owner id and then caches, so 100 requests from one workspace do
  not mean 100 database lookups. The cached value still rides on every
  upload, so no request lands in the dashboard as unauthenticated.
- **Safe by default.** `Authorization`, `Cookie`, `password`, `token`, `ssn`
  and friends are redacted before anything leaves your process. Bodies with
  nothing to redact are passed through byte for byte, so your payloads are
  never re-serialized on the way out.
- **Error triage.** 4xx/5xx responses get `x-log-url` and `x-debug` headers
  and a `debug` block in the JSON body. If someone attaches a "next steps"
  message to an error in the dashboard, the SDK injects it as
  `debug.recovery` - read synchronously from an in-process cache, never
  blocking the response on a network call. A 5xx that groups by its throw
  site also reports the key it would have grouped under otherwise, so a
  message you attached before that grouping existed keeps being injected.
- **Blocking.** Return `{ block: true }` from the setup callback to reject a
  request before your handler runs, or
  `{ block: { status: 402, message: "Payment required" } }` to pick the
  status.

## The setup callback

It receives a small read-only request view and returns a hash:

| field | what |
|---|---|
| `api_key` | The **masked** end-user key. Always `CLIENT.mask(raw_header)` - never substitute `"anonymous"`, whose last 4 characters would become the mask tail. |
| `owner[:id]` | The permanent, immutable workspace/tenant identifier. |
| `owner[:enrich]` | `->(id) { ... }` returning owner metadata (`label`, `email`, extras). The only channel for owner metadata; anything else inline on `owner` is dropped. |
| `block` | `true`, or `{ status:, message: }`. |
| anything else | Carried through onto the log as-is. Keep it cheap - read straight off the request. Anything expensive belongs in `enrich`. |

The request view exposes `header(name)` (case-insensitive),
`request_method`, `path`, `query_string`, `url`, and the raw Rack `env`.

## Route patterns

The middleware reads the matched route template from the framework so your
handlers do not have to report it:

| framework | source | reported as |
|---|---|---|
| Sinatra | `env["sinatra.route"]` (`GET /pets/:id`) | `/pets/{id}` |
| Rails | `env["action_dispatch.route_uri_pattern"]` | `/pets/{id}` |
| anything | `env["restless.route"]`, set by you | as given |

The method prefix is stripped and `:id`-style params are rewritten to
`{id}`, so the same endpoint produces the same `routePattern` here as it
does in the Node, Python and Go SDKs. Override the whole thing with a
lambda:

```ruby
use CLIENT.rack(route: ->(env) { env["my_router.pattern"] })
```

## Never breaks your API

Observability must not take down a production request path. Upload failures,
callback exceptions, unserializable bodies and malformed input are all caught
and swallowed (surfaced only under `DEBUG=restless`). Uploads happen on a
background thread and are fire-and-forget. Streaming responses
(`text/event-stream`) and bodies over 1 MiB are never buffered.

An exception your app raises is captured with its stack - so the error
fingerprint keys on the method that raised, not on the middleware - and then
re-raised untouched, leaving your own error handling completely unaffected.

## Environment variables

| variable | purpose |
|---|---|
| `RESTLESS_KEY` | Your project API key, if you do not pass one explicitly. |
| `RESTLESS_BASE_URL` | Override the ingest URL (self-hosted or staging). |
| `RESTLESS_ENV` / `RACK_ENV` / `RAILS_ENV` | `production` enables batching; anything else flushes every request. `test` disables uploads entirely. |
| `DEBUG=restless` | Print upload diagnostics to stderr. |

## Conformance

This SDK implements version 1.0.0 of the Restless SDK Contract at level L2,
and is verified against the shared cross-language conformance vectors and a
differential fuzzer run against the reference implementation. See
[CONFORMANCE.md](./CONFORMANCE.md).

## License
MIT
