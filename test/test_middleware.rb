# frozen_string_literal: true

# Level 2 behaviour: the capture engine, the two caches, injection, batching
# and the safety guarantees. None of it is covered by the shared vectors
# (CONTRACT.md sections 8 to 13 are verified per-SDK), so it is covered here.
#
#     ruby -Ilib -Itest test/test_middleware.rb

require "minitest/autorun"
require "json"
require "stringio"

require "restless"

require_relative "fixtures/src/exploder"

class TestMiddleware < Minitest::Test
  # A transport stand-in. `call(url, headers, body) -> [status, body]`.
  class Recorder
    attr_reader :batches, :headers

    def initialize(response = { "recoveryMessages" => {} })
      @batches = []
      @headers = []
      @response = response
    end

    def to_proc
      lambda do |_url, headers, body|
        @headers << headers
        @batches << JSON.parse(body)
        [202, JSON.generate(@response)]
      end
    end

    def entries
      @batches.flatten
    end
  end

  def setup
    # BATCH-008 would otherwise drop every capture: this file IS a test run.
    ENV["RESTLESS_SETUP_MODE"] = "1"
  end

  def teardown
    ENV.delete("RESTLESS_SETUP_MODE")
  end

  def client(recorder, **options)
    Restless::Client.new("proj_key", base_url: "http://localhost:9999",
                                     transport: recorder.to_proc, **options)
  end

  def env_for(path, method: "GET", query: "", headers: {}, body: nil, content_type: nil)
    env = {
      "REQUEST_METHOD" => method,
      "PATH_INFO" => path,
      "SCRIPT_NAME" => "",
      "QUERY_STRING" => query,
      "SERVER_NAME" => "localhost",
      "SERVER_PORT" => "8086",
      "rack.url_scheme" => "http",
      "rack.input" => StringIO.new(body.to_s)
    }
    env["CONTENT_TYPE"] = content_type if content_type
    headers.each { |k, v| env["HTTP_#{k.upcase.tr('-', '_')}"] = v }
    env
  end

  def capture(index)
    {
      "requestId" => index.to_s,
      "startedAt" => "2026-01-01T00:00:00.000Z",
      "duration" => 1,
      "request" => { "method" => "GET", "url" => "http://x/y", "headers" => {} },
      "response" => { "status" => 200, "headers" => {} }
    }
  end

  def with_env(vars)
    previous = vars.keys.map { |k| [k, ENV[k]] }
    vars.each { |k, v| ENV[k] = v }
    yield
  ensure
    previous.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  # FP-047 fixtures. `Exploder` lives under a `src/` directory, so FP-042
  # rewrites its path to `src/exploder.rb` on any machine.
  STACK_KEY = "500:src/exploder.rb:detonate"
  # What the ladder produces without the stack strategy: the `message` rung,
  # against the normalized route and the normalized response message.
  STACK_PREVIOUS_KEY = "500:GET:/boom:the-widget-frobnicator-is-on-fire"

  # A 500 the framework caught itself. It leaves the exception in the Rack env,
  # which is the only way to reach the `stack` strategy for a handled error,
  # and unlike an uncaught raise it still runs the injection path.
  def handled_500_app
    lambda do |env|
      env["sinatra.route"] = "GET /boom"
      begin
        Exploder.detonate
      rescue StandardError => e
        env["rack.exception"] = e
      end
      body = JSON.generate("message" => "the widget frobnicator is on fire")
      [500,
       { "Content-Type" => "application/json", "Content-Length" => body.bytesize.to_s },
       [body]]
    end
  end

  def json_app(status, payload, route: nil)
    lambda do |env|
      env["sinatra.route"] = route if route
      body = JSON.generate(payload)
      [status,
       { "Content-Type" => "application/json", "Content-Length" => body.bytesize.to_s },
       [body]]
    end
  end

  # --- wire payload -------------------------------------------------------

  def test_wire_payload_shape
    recorder = Recorder.new
    c = client(recorder)
    c.setup { |req| { api_key: c.mask(req.header("Authorization")), owner: { id: "ws_acme" } } }
    mw = c.rack.new(json_app(200, { "ok" => true }))

    mw.call(env_for("/pets", headers: { "authorization" => "Bearer sk_live_abcdef" }))
    c.flush

    entry = recorder.entries.first
    assert_equal "127.0.0.1", entry["clientIPAddress"] # WIRE-018
    assert_equal false, entry["development"]
    assert_equal "ws_acme", entry["group"]["id"]       # WIRE-012
    assert_equal [], entry["group"]["emails"]          # WIRE-013
    assert_equal "ws_acme", entry["projectId"]         # WIRE-015/019
    assert entry["apiKey"].start_with?("sha512-")      # WIRE-014
    refute entry.key?("errorFingerprint")              # WIRE-017
    log = entry["request"]["log"]
    assert_equal "1.2", log["version"]
    assert_equal "restless-sdk-ruby", log["creator"]["name"] # WIRE-016
    assert_equal 1, log["entries"].length
    assert Restless::RequestId::UUID_RE.match?(entry["_id"]) # WIRE-011
    # META-002.
    assert_equal Restless::SPEC_VERSION, recorder.headers.first["X-Restless-Spec-Version"]
    assert_equal "Bearer proj_key", recorder.headers.first["Authorization"] # WIRE-003
  end

  # --- redaction choke point ---------------------------------------------

  def test_redaction_runs_before_upload
    recorder = Recorder.new
    c = client(recorder, redact: { body_keys: ["microchip_id"] })
    c.setup { |_req| {} }
    mw = c.rack.new(json_app(201, { "created" => true }))

    body = JSON.generate("name" => "Bruno", "password" => "hunter2hunter2",
                         "microchip_id" => "CHIP-00998877", "big_id" => 9_007_199_254_740_993)
    mw.call(env_for("/pets", method: "POST", query: "api_key=sk_leaked_in_url&page=2",
                             headers: { "authorization" => "Bearer sk_live_abcdef123456" },
                             content_type: "application/json", body: body))
    c.flush

    har = recorder.entries.first["request"]["log"]["entries"].first
    headers = har["request"]["headers"].map { |h| [h["name"], h["value"]] }.to_h

    # REDACT-016: the auth scheme survives, the credential does not.
    assert_equal "Bearer <REDACTED:20:3456>", headers["authorization"]
    # REDACT-025: rewritten in place, `page` untouched.
    assert_includes har["request"]["url"], "api_key=%3CREDACTED%3A16%3A_url%3E&page=2"
    text = har["request"]["postData"]["text"]
    assert_includes text, %("password":"<REDACTED:14:ter2>")
    # REDACT-015: the constructor list is additive on top of the defaults.
    assert_includes text, %("microchip_id":"<REDACTED:13:8877>")
    # PRIM-033: an int64 must survive a body that DID have to be re-serialized.
    assert_includes text, %("big_id":9007199254740993)
  end

  # REDACT-010 regression. U+212A KELVIN SIGN full-lowercases to `k`, so a
  # header named `x-api-Key` or a body key `toKen` spelled with it IS
  # denylisted and MUST be redacted.
  #
  # This shipped broken. Name normalization used an ASCII-only fold, written
  # under an ASCII-only fold, and the secret went
  # to the dashboard in plaintext. The vectors pin it too
  # (`redactHeaders/unicode-fold-kelvin`, `redactBody/unicode-fold-kelvin`);
  # this test pins it again locally so a change to Text.full_lower cannot
  # reintroduce the bypass in a repo where the vectors have not been
  # re-vendored yet.
  def test_kelvin_sign_does_not_bypass_the_denylist
    kelvin = [0x212A].pack("U")
    refute_equal "K", kelvin, "U+212A is not ASCII capital K"
    assert_equal "k", kelvin.downcase,
                 "String#downcase must full-lowercase U+212A, or REDACT-010 cannot hold"

    # The normalization itself.
    assert_equal "token", Restless::Redact.normalize_name("to#{kelvin}en")
    assert_equal "xapikey", Restless::Redact.normalize_name("x-api-#{kelvin}ey")

    # Through the public entry points.
    assert_equal({ "x-api-#{kelvin}ey" => "<REDACTED:16:alue>" },
                 Restless::Redact.redact_headers("x-api-#{kelvin}ey" => "supersecretvalue"))
    assert_equal %({"to#{kelvin}en":"<REDACTED:16:alue>"}),
                 Restless::Redact.redact_body(%({"to#{kelvin}en":"supersecretvalue"}),
                                              "application/json")

    # And end to end, at the choke point, which is the thing that matters.
    recorder = Recorder.new
    c = client(recorder)
    c.setup { |_req| {} }
    mw = c.rack.new(json_app(201, { "created" => true }))
    mw.call(env_for("/pets", method: "POST",
                             query: "api_#{kelvin}ey=sk_leaked_in_url",
                             headers: { "x-api-#{kelvin}ey" => "supersecretvalue" },
                             content_type: "application/json",
                             body: %({"to#{kelvin}en":"supersecretvalue"})))
    c.flush

    har = recorder.entries.first["request"]["log"]["entries"].first
    headers = har["request"]["headers"].map { |h| [h["name"], h["value"]] }.to_h
    # Rack reconstructs header names from the `HTTP_*` env keys and downcases
    # them on the way, so the sign is already gone by the time Redact sees it.
    # Header names are ASCII on the wire; the body and query below are where a
    # KELVIN SIGN genuinely survives to the denylist check.
    assert_equal "<REDACTED:16:alue>", headers["x-api-key"]
    assert_includes har["request"]["postData"]["text"], "<REDACTED:16:alue>"
    assert_includes har["request"]["url"], "%3CREDACTED%3A16%3A_url%3E"
    refute_includes JSON.generate(recorder.entries), "supersecretvalue"
    refute_includes JSON.generate(recorder.entries), "sk_leaked_in_url"
  end

  # PRIM-013 regression, and the reason the KELVIN case above is tested end to
  # end rather than only against Redact.
  #
  # `rack.input` is binary per the Rack spec and `IO#read(n)` returns ASCII-8BIT
  # regardless, so a captured body reaches Text.to_utf8 tagged BINARY. Ruby
  # transcodes BINARY to UTF-8 with no mapping above 0x7F, so every byte of
  # every multi-byte character used to become its own U+FFFD.
  def test_a_non_ascii_body_survives_capture_intact
    recorder = Recorder.new
    c = client(recorder)
    c.setup { |_req| {} }
    mw = c.rack.new(json_app(200, { "ok" => true }))

    body = JSON.generate("name" => "Bruño 🐕", "note" => "日本語")
    mw.call(env_for("/pets", method: "POST", content_type: "application/json", body: body))
    c.flush

    har = recorder.entries.first["request"]["log"]["entries"].first
    text = har["request"]["postData"]["text"]
    assert_equal body, text
    refute_includes text, [0xFFFD].pack("U")
  end

  # --- fingerprints + injection ------------------------------------------

  def test_404_on_a_parameterized_route_is_resource
    recorder = Recorder.new
    c = client(recorder)
    c.setup { |_req| {} }
    mw = c.rack.new(json_app(404, { "code" => "pet_not_found" }, route: "GET /pets/:id"))

    status, headers, body = mw.call(env_for("/pets/99"))
    c.flush

    assert_equal 404, status
    entry = recorder.entries.first
    # FP-012: 404 is intercepted BEFORE the body-code strategy.
    assert_equal "resource", entry["errorFingerprint"]["strategy"]
    assert_equal "404:resource", entry["errorFingerprint"]["key"]
    # The Sinatra route is normalized to the shape every other SDK reports.
    assert_equal "/pets/{id}", entry["routePattern"]

    # INJECT-002.
    assert headers["x-log-url"].start_with?("http://localhost:9999/logs/")
    assert headers["x-debug"].start_with?("npx api debug ")
    # INJECT-004: the dig-in line is always present.
    parsed = JSON.parse(body.join)
    assert_includes parsed["debug"]["recovery"], "/get-pets-id.md"
    # INJECT-008.
    assert_equal body.join.bytesize.to_s, headers["content-length"]
  end

  def test_404_on_no_route_is_endpoint
    recorder = Recorder.new
    c = client(recorder)
    c.setup { |_req| {} }
    mw = c.rack.new(json_app(404, { "error" => "no_such_endpoint" }))

    mw.call(env_for("/nope"))
    c.flush
    assert_equal "404:endpoint", recorder.entries.first["errorFingerprint"]["key"]
  end

  def test_body_code_strategy
    recorder = Recorder.new
    c = client(recorder)
    c.setup { |_req| {} }
    mw = c.rack.new(json_app(418, { "code" => "im_a_teapot" }, route: "GET /teapot"))

    mw.call(env_for("/teapot"))
    c.flush
    fingerprint = recorder.entries.first["errorFingerprint"]
    assert_equal "body-code", fingerprint["strategy"]
    assert_equal "418:im_a_teapot", fingerprint["key"]
  end

  # CACHE-011, CACHE-012. The second occurrence of an error carries advice.
  def test_recovery_message_round_trip
    recorder = Recorder.new("recoveryMessages" => { "404:resource" => "Call GET /pets first." },
                            "docsUrl" => "http://docs.test/")
    c = client(recorder)
    c.setup { |_req| {} }
    mw = c.rack.new(json_app(404, { "code" => "pet_not_found" }, route: "GET /pets/:id"))

    _, _, first = mw.call(env_for("/pets/99"))
    c.flush
    refute_includes JSON.parse(first.join)["debug"]["recovery"], "Call GET /pets first."

    _, headers, second = mw.call(env_for("/pets/98"))
    c.flush
    recovery = JSON.parse(second.join)["debug"]["recovery"]
    assert_includes recovery, "Call GET /pets first."
    assert_includes recovery, "For the accepted parameters and next steps"
    # WIRE-023: the docs origin is learned from the server, trailing slash
    # stripped, and used for injected links from then on.
    assert headers["x-log-url"].start_with?("http://docs.test/logs/")
  end

  # FP-047. Turning the `stack` strategy on MOVES the key for every uncaught
  # 5xx, which would silently orphan whatever Agent Recovery message the
  # customer had already attached to the old one. The fingerprint therefore
  # carries the displaced key, the uploader sends BOTH so the ingest can answer
  # for either, and the lookup falls back to it.
  #
  # This is the whole transition in one test: the message is attached ONLY to
  # the pre-stack-strategy key and must still be injected.
  def test_a_recovery_message_on_the_previous_key_is_still_injected
    recorder = Recorder.new("recoveryMessages" => { STACK_PREVIOUS_KEY => "Retry with a smaller page." })
    c = client(recorder)
    c.setup { |_req| {} }
    mw = c.rack.new(handled_500_app)

    mw.call(env_for("/boom"))
    c.flush

    fingerprint = recorder.entries.first["errorFingerprint"]
    assert_equal "stack", fingerprint["strategy"]
    assert_equal STACK_KEY, fingerprint["key"]
    # The displaced key rides along on the wire so the ingest can answer for it.
    assert_equal STACK_PREVIOUS_KEY, fingerprint["previousKey"]

    # Second occurrence: the current key is a confirmed miss, so the lookup
    # falls back. Reaching the cache at all also proves the uploader sent the
    # previous key, since only keys in the batch are cached from a response.
    _, _, body = mw.call(env_for("/boom"))
    c.flush
    assert_includes JSON.parse(body.join)["debug"]["recovery"], "Retry with a smaller page."
  end

  # FP-047. The current key is preferred, so a message attached to the NEW
  # group wins the moment one exists and the transitional fallback stops
  # mattering.
  def test_a_message_on_the_current_key_wins_over_the_previous_key
    recorder = Recorder.new("recoveryMessages" => {
                              STACK_KEY => "Current guidance.",
                              STACK_PREVIOUS_KEY => "Stale guidance."
                            })
    c = client(recorder)
    c.setup { |_req| {} }
    mw = c.rack.new(handled_500_app)

    mw.call(env_for("/boom"))
    c.flush

    _, _, body = mw.call(env_for("/boom"))
    c.flush
    recovery = JSON.parse(body.join)["debug"]["recovery"]
    assert_includes recovery, "Current guidance."
    refute_includes recovery, "Stale guidance."
  end

  # CACHE-001, CACHE-003.
  def test_enrich_runs_once_per_owner
    recorder = Recorder.new
    calls = []
    c = client(recorder)
    c.setup do |req|
      workspace = req.header("X-Workspace-Id")
      { api_key: c.mask(req.header("Authorization")),
        owner: { id: workspace,
                 enrich: lambda { |id|
                   calls << id
                   { "label" => "Acme", "email" => "ops@acme.test" }
                 } } }
    end
    mw = c.rack.new(json_app(200, { "ok" => true }))

    3.times { mw.call(env_for("/pets", headers: { "x-workspace-id" => "ws_acme" })) }
    mw.call(env_for("/pets", headers: { "x-workspace-id" => "ws_hooli" }))
    c.flush

    assert_equal %w[ws_acme ws_hooli], calls
    groups = recorder.entries.map { |e| e["group"] }
    # CACHE-003: every upload carries the metadata, not just the first.
    assert_equal 3, groups.count { |g| g["id"] == "ws_acme" && g["label"] == "Acme" }
    assert_equal [["ops@acme.test"]], groups.map { |g| g["emails"] }.uniq.first(1)
  end

  # CACHE-005 / SAFETY-003.
  def test_enrich_failure_is_swallowed_and_not_cached
    recorder = Recorder.new
    calls = 0
    c = client(recorder)
    c.setup do |_req|
      { owner: { id: "ws_bad", enrich: lambda { |_id| calls += 1; raise "db down" } } }
    end
    mw = c.rack.new(json_app(200, { "ok" => true }))

    2.times { mw.call(env_for("/pets")) }
    c.flush

    assert_equal 2, calls, "a failed enrich must not be cached"
    # CACHE-007: the bare owner id still ships.
    assert_equal "ws_bad", recorder.entries.first["group"]["id"]
  end

  # SETUP-004.
  def test_block_rejects_before_the_handler
    recorder = Recorder.new
    reached = false
    c = client(recorder)
    c.setup { |_req| { block: { status: 402, message: "Payment required" } } }
    mw = c.rack.new(->(_env) { reached = true; [200, {}, ["never"]] })

    status, _headers, body = mw.call(env_for("/pets"))
    c.flush

    refute reached
    assert_equal 402, status
    assert_equal({ "error" => "Payment required" }, JSON.parse(body.join).reject { |k, _| k == "debug" })
    assert_equal 402, recorder.entries.first["request"]["log"]["entries"].first["response"]["status"]
  end

  # SAFETY-001, SAFETY-002.
  def test_a_raising_setup_callback_never_reaches_the_app
    recorder = Recorder.new
    c = client(recorder)
    c.setup { |_req| raise "boom in the callback" }
    mw = c.rack.new(json_app(200, { "ok" => true }))

    status, = mw.call(env_for("/pets"))
    assert_equal 200, status
  end

  # SAFETY-001 and the `stack` strategy: the customer's exception is captured
  # and then re-raised untouched.
  def test_an_uncaught_exception_is_captured_and_re_raised
    recorder = Recorder.new
    c = client(recorder)
    c.setup { |_req| {} }
    mw = c.rack.new(->(_env) { Exploder.detonate })

    assert_raises(RuntimeError) { mw.call(env_for("/crash")) }
    c.flush

    fingerprint = recorder.entries.first["errorFingerprint"]
    assert_equal "stack", fingerprint["strategy"]
    # FP-043: keyed on the RAISING method, not the middleware.
    assert fingerprint["key"].end_with?(":detonate"), fingerprint["key"]
    assert fingerprint["key"].start_with?("500:src/exploder.rb:"), fingerprint["key"]
  end

  # REQID-003, REQID-010.
  def test_request_id_headers
    recorder = Recorder.new
    c = client(recorder)
    c.setup { |_req| {} }
    mw = c.rack.new(json_app(200, { "ok" => true }))

    _, fresh, = mw.call(env_for("/pets"))
    assert Restless::RequestId::UUID_RE.match?(fresh["x-request-id"])
    refute fresh.key?("x-restless-id")

    _, chained, = mw.call(env_for("/pets", headers: { "x-request-id" => "upstream-value" }))
    assert Restless::RequestId::UUID_RE.match?(chained["x-restless-id"])
    refute_equal "upstream-value", chained["x-restless-id"]
  end

  # BATCH-001, BATCH-005.
  def test_batches_of_ten_in_production
    with_env("RESTLESS_ENV" => "production") do
      recorder = Recorder.new
      uploader = Restless::Uploader.new(api_key: "k", base_url: "https://ingress.example",
                                        transport: recorder.to_proc)
      25.times { |i| uploader.push(capture(i)) }
      uploader.flush

      # Sorted because uploads are fire-and-forget on background threads
      # (SAFETY-008), so the batches can land in any order.
      assert_equal [5, 10, 10], recorder.batches.map(&:length).sort
    end
  end

  # BATCH-003. Outside production every push flushes immediately, which is
  # what keeps the customer dev loop low-latency.
  def test_non_production_flushes_every_push
    with_env("RESTLESS_ENV" => "development") do
      recorder = Recorder.new
      uploader = Restless::Uploader.new(api_key: "k", base_url: "https://ingress.example",
                                        transport: recorder.to_proc)
      3.times { |i| uploader.push(capture(i)) }
      uploader.flush

      assert_equal [1, 1, 1], recorder.batches.map(&:length)
    end
  end

  # BATCH-003. A localhost ingest flushes immediately even in production.
  def test_localhost_flushes_every_push_in_production
    with_env("RESTLESS_ENV" => "production") do
      recorder = Recorder.new
      uploader = Restless::Uploader.new(api_key: "k", base_url: "http://localhost:8099",
                                        transport: recorder.to_proc)
      2.times { |i| uploader.push(capture(i)) }
      uploader.flush

      assert_equal [1, 1], recorder.batches.map(&:length)
    end
  end

  # BATCH-004. The OLDEST entry is dropped, never the newest: the newest are
  # the ones an operator is actively debugging.
  def test_queue_drops_the_oldest_entry_when_full
    with_env("RESTLESS_ENV" => "production") do
      recorder = Recorder.new
      uploader = Restless::Uploader.new(api_key: "k", base_url: "https://ingress.example",
                                        transport: recorder.to_proc)
      # Fill the queue the way a metrics-server outage would.
      queue = uploader.instance_variable_get(:@queue)
      Restless::Uploader::MAX_QUEUE.times { |i| queue << capture(i) }
      uploader.push(capture(9_999))
      uploader.flush

      batch = recorder.batches.first
      assert_equal Restless::Uploader::MAX_QUEUE, batch.length
      assert_equal "1", batch.first["_id"], "the OLDEST entry should have been dropped"
      assert_equal "9999", batch.last["_id"]
    end
  end

  # BATCH-006, BATCH-007.
  def test_flush_without_a_key_drops_the_batch
    recorder = Recorder.new
    uploader = Restless::Uploader.new(api_key: "", base_url: "https://ingress.example",
                                      transport: recorder.to_proc)
    uploader.flush # empty queue: a no-op, must not raise
    uploader.instance_variable_get(:@queue) << capture(1)
    uploader.flush

    assert_empty recorder.batches
    assert_empty uploader.instance_variable_get(:@queue)
  end

  # SAFETY-007. A streaming body is passed straight through, unbuffered.
  def test_streaming_responses_are_not_buffered
    recorder = Recorder.new
    c = client(recorder)
    c.setup { |_req| {} }
    streamed = Object.new
    def streamed.each
      yield "data: one\n\n"
    end
    mw = c.rack.new(->(_env) { [200, { "Content-Type" => "text/event-stream" }, streamed] })

    _, _, body = mw.call(env_for("/stream"))
    c.flush

    assert_same streamed, body
    har = recorder.entries.first["request"]["log"]["entries"].first
    assert_equal(-1, har["response"]["bodySize"]) # HAR-011
    assert_equal 0, har["response"]["content"]["size"]
  end
end

require_relative "fixtures/src/exploder"
