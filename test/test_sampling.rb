# frozen_string_literal: true

# Sampling at runtime (CONTRACT.md section 12.1). The decision logic itself is
# pinned by spec/vectors/sampling.json through test_vectors.rb; this file is
# about what the middleware DOES with the outcome: which headers go out, what
# gets uploaded, and the config report.
#
#     ruby -Ilib -Itest test/test_sampling.rb

require "minitest/autorun"
require "json"
require "stringio"
require "tmpdir"
require "fileutils"

require "restless"

class TestSampling < Minitest::Test
  SAMPLING = {
    routes: {
      "GET /health" => "off",
      "GET /status" => "errors",
      "GET /pets" => 0.5
    }
  }.freeze

  # Every request the SDK makes, split by endpoint.
  class Collector
    attr_reader :uploads, :upload_headers, :reports

    def initialize(&respond)
      @uploads = []
      @upload_headers = []
      @reports = []
      @respond = respond || -> { {} }
      @mutex = Mutex.new
    end

    def to_proc
      lambda do |url, headers, body|
        report = url.end_with?("/v1/sampling")
        @mutex.synchronize do
          if report
            @reports << JSON.parse(body)
          else
            @uploads.concat(JSON.parse(body))
            @upload_headers << headers
          end
        end
        # Only an upload response is parsed by the SDK, so only an upload
        # consumes `respond`.
        [202, report ? "" : JSON.generate(@respond.call)]
      end
    end
  end

  # Counts draws, so a test can assert there was exactly one per request.
  class FixedRandom
    attr_reader :calls

    def initialize(value)
      @value = value
      @calls = 0
    end

    def call
      @calls += 1
      @value
    end
  end

  def setup
    # BATCH-008 and SAMPLE-051 would otherwise send nothing: this IS a test run.
    ENV["RESTLESS_SETUP_MODE"] = "1"
  end

  def teardown
    ENV.delete("RESTLESS_SETUP_MODE")
  end

  def client(collector, sampling: SAMPLING, key: "proj_key", random: nil)
    c = Restless::Client.new(key, base_url: "http://localhost:9999",
                                  transport: collector.to_proc, sampling: sampling)
    c.engine.random = random if random
    c.setup { |_req| {} }
    c
  end

  def env_for(path, method: "GET", body: nil)
    {
      "REQUEST_METHOD" => method,
      "PATH_INFO" => path,
      "SCRIPT_NAME" => "",
      "QUERY_STRING" => "",
      "SERVER_NAME" => "localhost",
      "SERVER_PORT" => "8086",
      "rack.url_scheme" => "http",
      "rack.input" => StringIO.new(body.to_s),
      "CONTENT_TYPE" => "application/json"
    }
  end

  # Serves one request whose route pattern is the literal path, the way a
  # router would report it.
  def app(status: 200, body: '{"ok":true}')
    lambda do |env|
      env["restless.route"] = env["PATH_INFO"]
      [status, { "Content-Type" => "application/json" }, [body]]
    end
  end

  def call(client, path, method: "GET", **app_options)
    status, headers, body = client.rack.new(app(**app_options)).call(env_for(path, method: method, body: '{"q":1}'))
    text = +""
    body.each { |chunk| text << chunk }
    [status, headers, text]
  end

  def id_header?(headers)
    headers.keys.any? { |k| %w[x-request-id x-restless-id].include?(k.to_s.downcase) }
  end

  # --- outcomes through the middleware ------------------------------------

  def test_off_leaves_the_response_untouched_with_no_id_header_and_no_log
    collector = Collector.new
    c = client(collector)
    response = [200, { "Content-Type" => "application/json" }, ['{"ok":true}']]
    returned = c.rack.new(->(_env) { response }).call(env_for("/health").merge("restless.route" => "/health"))
    c.flush

    # SAMPLE-033: the very same headers and body, unread.
    assert_equal 200, returned[0]
    assert_same response[1], returned[1]
    assert_same response[2], returned[2]
    refute id_header?(returned[1])
    refute returned[1].key?("x-debug")
    refute returned[1].key?("x-api-feedback")
    assert_equal [], collector.uploads
  end

  def test_off_drops_errors_too
    collector = Collector.new
    c = client(collector)
    status, headers, text = call(c, "/health", status: 503, body: '{"error":"down"}')
    c.flush

    assert_equal 503, status
    refute id_header?(headers)
    refute headers.key?("x-debug")
    refute headers.key?("x-api-feedback")
    # No `debug` object merged into the body (INJECT-001).
    assert_equal({ "error" => "down" }, JSON.parse(text))
    assert_equal [], collector.uploads
  end

  def test_errors_drops_a_success_headers_and_all
    collector = Collector.new
    c = client(collector)
    _, headers, = call(c, "/status")
    c.flush

    refute id_header?(headers)
    refute headers.key?("x-api-feedback")
    assert_equal [], collector.uploads
  end

  def test_errors_sends_an_error_in_full
    collector = Collector.new
    c = client(collector)
    _, headers, = call(c, "/status", status: 404, body: '{"error":"nope"}')
    c.flush

    assert id_header?(headers)
    assert_equal 1, collector.uploads.length
    refute collector.uploads[0].key?("sampled")
    assert collector.uploads[0].key?("errorFingerprint")
  end

  def test_a_rate_miss_uploads_a_bodyless_stub_still_headered
    collector = Collector.new
    c = client(collector, random: FixedRandom.new(0.9))
    _, headers, text = call(c, "/pets", body: '{"pets":[1,2]}')
    c.flush

    # The stub is a real log, so the caller can still be pointed at it.
    assert id_header?(headers)
    assert headers.key?("x-debug")
    assert headers.key?("x-api-feedback")
    assert_equal({ "pets" => [1, 2] }, JSON.parse(text))
    assert_equal 1, collector.uploads.length
    entry = collector.uploads[0]
    assert_equal true, entry["sampled"] # WIRE-030
    har = entry["request"]["log"]["entries"][0]
    refute har["request"].key?("postData")
    assert_equal(-1, har["request"]["bodySize"])
    assert_equal "", har["response"]["content"]["text"]
    assert_equal(-1, har["response"]["bodySize"])
    assert_equal 200, har["response"]["status"]
  end

  def test_a_rate_hit_uploads_in_full
    collector = Collector.new
    c = client(collector, random: FixedRandom.new(0.1))
    call(c, "/pets", body: '{"pets":[1,2]}')
    c.flush

    assert_equal 1, collector.uploads.length
    refute collector.uploads[0].key?("sampled")
    text = collector.uploads[0]["request"]["log"]["entries"][0]["response"]["content"]["text"]
    assert_equal({ "pets" => [1, 2] }, JSON.parse(text))
  end

  def test_an_unconfigured_route_uses_the_default
    collector = Collector.new
    c = client(collector)
    _, headers, = call(c, "/orders")
    c.flush

    assert id_header?(headers)
    assert_equal 1, collector.uploads.length
    refute collector.uploads[0].key?("sampled")
  end

  def test_a_request_with_no_route_uses_the_default
    collector = Collector.new
    c = client(collector, sampling: { default: "off" })
    returned = c.rack.new(->(_env) { [200, {}, ["x"]] }).call(env_for("/anything"))
    c.flush

    refute id_header?(returned[1])
    assert_equal [], collector.uploads
  end

  def test_draws_u_once_per_request
    random = FixedRandom.new(0.9)
    c = client(Collector.new, random: random)
    call(c, "/pets")
    c.flush

    assert_equal 1, random.calls # SAMPLE-032
  end

  def test_no_draw_without_sampling
    random = FixedRandom.new(0.9)
    c = client(Collector.new, sampling: nil, random: random)
    call(c, "/pets")

    assert_equal 0, random.calls
  end

  def test_a_raised_exception_under_off_is_re_raised_and_not_logged
    collector = Collector.new
    c = client(collector)
    mw = c.rack.new(lambda do |env|
      env["restless.route"] = "/health"
      raise ArgumentError, "boom"
    end)

    assert_raises(ArgumentError) { mw.call(env_for("/health")) }
    c.flush
    assert_equal [], collector.uploads
  end

  def test_a_raised_exception_under_a_rate_is_logged_in_full
    collector = Collector.new
    c = client(collector, random: FixedRandom.new(0.99))
    mw = c.rack.new(lambda do |env|
      env["restless.route"] = "/pets"
      raise ArgumentError, "boom"
    end)

    assert_raises(ArgumentError) { mw.call(env_for("/pets")) }
    c.flush
    assert_equal 1, collector.uploads.length
    refute collector.uploads[0].key?("sampled")
  end

  def test_a_blocked_request_follows_its_route_mode
    collector = Collector.new
    c = client(collector)
    c.setup { |_req| { block: true } }
    status, headers, = c.rack.new(app).call(env_for("/health").merge("restless.route" => "/health"))
    c.flush

    assert_equal 403, status
    refute id_header?(headers)
    assert_equal [], collector.uploads
  end

  # A Rack 3 streaming body responds to `call`, not `each`. A drop hands it
  # back as is and a stub never reads it.
  def test_streaming_bodies_pass_through_untouched
    streaming = ->(stream) { stream.write("chunk") }
    [["/health", nil], ["/pets", 0.9]].each do |path, u|
      collector = Collector.new
      c = client(collector, random: u && FixedRandom.new(u))
      mw = c.rack.new(lambda do |env|
        env["restless.route"] = path
        [200, { "content-type" => "text/plain" }, streaming]
      end)
      _, _, body = mw.call(env_for(path))
      c.flush

      assert_same streaming, body
    end
  end

  def test_a_partial_hijack_callable_survives
    hijack = ->(io) { io.write("x") }
    collector = Collector.new
    c = client(collector, sampling: nil)
    mw = c.rack.new(->(_env) { [200, { "rack.hijack" => hijack }, []] })
    _, headers, = mw.call(env_for("/upgrade"))
    c.flush

    assert_same hijack, headers["rack.hijack"]
    captured = collector.uploads[0]["request"]["log"]["entries"][0]["response"]["headers"]
    refute(captured.any? { |h| h["name"] == "rack.hijack" })
  end

  # --- the config report and the upload header ----------------------------

  def test_reports_once_per_process_on_the_first_request_with_the_normalized_config
    collector = Collector.new
    c = client(collector, sampling: { routes: { "get /pets/:id/" => 0.25, "GET /health" => :off } })
    # Constructing and mounting sends nothing (SAMPLE-051).
    c.rack.new(app)
    assert_equal [], collector.reports

    3.times { call(c, "/orders") }
    c.flush

    assert_equal 1, collector.reports.length
    report = collector.reports[0]
    assert_match(/\A[0-9a-f]{64}\z/, report["hash"])
    assert_equal "on", report["default"]
    assert_equal({ "GET /health" => "off", "GET /pets/{id}" => 0.25 }, report["routes"])
    assert_equal({ "name" => Restless::SDK_NAME, "version" => Restless::VERSION }, report["creator"])

    refute_empty collector.upload_headers
    collector.upload_headers.each do |headers|
      assert_equal report["hash"], headers["x-restless-sampling"] # SAMPLE-052
    end
  end

  def test_the_report_hash_is_the_canonical_hash
    collector = Collector.new
    c = client(collector, sampling: { default: "errors" })
    call(c, "/x", status: 500)
    c.flush

    expected = Digest::SHA256.hexdigest("default\terrors\n")
    assert_equal expected, collector.reports[0]["hash"]
  end

  def test_re_sends_the_report_when_the_ingest_asks
    uploads = 0
    # Only the second upload asks, by which time the first report has long
    # finished: a report still in flight would rightly suppress the re-send.
    collector = Collector.new do
      uploads += 1
      { "needsSamplingConfig" => uploads == 2 }
    end
    c = client(collector, sampling: { default: "errors" })

    3.times do
      call(c, "/x", status: 500)
      c.flush
      c.flush # an upload's response starts the re-send; this waits for it
    end

    # The first report on the first request, then exactly one re-send for
    # the one response that asked.
    assert_equal 3, collector.uploads.length
    assert_equal 2, collector.reports.length
    assert_equal collector.reports[0], collector.reports[1]
  end

  def test_no_report_and_no_header_without_sampling_configured
    collector = Collector.new { { "needsSamplingConfig" => true } }
    c = client(collector, sampling: { default: "on", routes: {} })
    call(c, "/x")
    c.flush
    c.flush

    assert_equal [], collector.reports # SAMPLE-041
    assert_equal 1, collector.upload_headers.length
    refute collector.upload_headers[0].key?("x-restless-sampling")
  end

  def test_a_failed_report_never_reaches_the_request_path
    transport = lambda do |url, _headers, _body|
      raise Errno::ECONNREFUSED if url.end_with?("/v1/sampling")

      [202, "{}"]
    end
    c = Restless::Client.new("proj_key", base_url: "http://localhost:9999",
                                         transport: transport, sampling: { default: 0.5 })
    status, _, body = c.rack.new(app).call(env_for("/x"))
    c.flush

    assert_equal 200, status
    assert_equal ['{"ok":true}'], body
  end

  def test_no_report_without_a_key
    collector = Collector.new
    c = client(collector, key: "", sampling: { default: "errors" })
    with_no_key_env { call(c, "/x") }
    c.flush

    assert_equal [], collector.reports
  end

  def test_no_report_under_a_test_runner
    ENV.delete("RESTLESS_SETUP_MODE")
    collector = Collector.new
    c = client(collector, sampling: { default: "errors" })
    call(c, "/x", status: 500)
    c.flush

    assert_equal [], collector.reports
    assert_equal [], collector.uploads
  end

  # --- configuration ------------------------------------------------------

  def test_an_invalid_config_never_raises_and_falls_back_to_on
    collector = Collector.new
    c = client(collector, sampling: { default: "sometimes", routes: { "GET /pets" => 7 } })
    _, headers, = call(c, "/pets")
    c.flush

    assert id_header?(headers)
    assert_equal 1, collector.uploads.length
    refute collector.uploads[0].key?("sampled")
  end

  def test_a_non_hash_config_is_ignored
    c = client(Collector.new, sampling: "off")
    _, headers, = call(c, "/pets")
    assert id_header?(headers)
  end

  def test_symbols_are_the_ruby_spelling_of_the_string_modes
    config, warnings = Restless::Sampling.normalize(nil, default: :errors, routes: { "GET /a" => :off })
    assert_equal [], warnings
    assert_equal "errors", config.default
    assert_equal({ "GET /a" => "off" }, config.routes)
  end

  # SAMPLE-012: one bad key is ignored on its own. A key with invalid UTF-8
  # bytes must not discard the rest of the config.
  def test_a_key_with_invalid_bytes_is_ignored_alone
    bad = "GET /bad\xff".dup.force_encoding(Encoding::UTF_8)
    config, warnings = Restless::Sampling.normalize(nil, routes: { "GET /ok" => "off", bad => "off" })
    assert_equal({ "GET /ok" => "off" }, config.routes)
    assert_equal 1, warnings.length

    # SAMPLE-021: a route pattern that is not valid gets the default.
    off = Restless::Sampling::Config.new("off", {})
    assert_equal "off", Restless::Sampling.resolve_mode(off, "GET", "/bad\xff".dup.force_encoding(Encoding::UTF_8))
    assert_equal "off", Restless::Sampling.resolve_mode(off, "GET", "/café")
  end

  def test_string_keys_work_in_code_too
    config, = Restless::Sampling.normalize(nil, "default" => 0.1, "routes" => { "* /a" => "on" })
    assert_equal 0.1, config.default
    assert_equal({ "* /a" => "on" }, config.routes)
  end

  def test_settings_file_merges_with_code_code_winning_per_route
    Dir.mktmpdir("restless-sampling-") do |dir|
      FileUtils.mkdir_p(File.join(dir, ".restless"))
      File.write(File.join(dir, ".restless", "settings.json"), JSON.generate(
        "version" => 1,
        "apis" => [{ "id" => "a1", "name" => "Solo",
                     "sampling" => { "routes" => { "GET /a" => "off", "GET /b" => "off" } } }]
      ))
      Restless::Settings.reset_cache!
      collector = Collector.new
      begin
        c = Dir.chdir(dir) { client(collector, sampling: { routes: { "GET /b" => "on" } }) }
      ensure
        Restless::Settings.reset_cache!
      end

      call(c, "/a")
      c.flush
      assert_equal({ "GET /a" => "off", "GET /b" => "on" }, collector.reports[0]["routes"])
      # "GET /a" is off: nothing uploaded for it.
      assert_equal [], collector.uploads
    end
  end

  private

  def with_no_key_env
    saved = %w[RESTLESS_KEY README_API_KEY].map { |k| [k, ENV.delete(k)] }
    yield
  ensure
    saved.each { |k, v| ENV[k] = v if v }
  end
end
