# frozen_string_literal: true

# Upload backpressure: the in-flight cap, catch-up batches, retries and the
# upload timeout (CONTRACT.md WIRE-024 to WIRE-028, BATCH-005, BATCH-009/010).
#
#     ruby -Ilib -Itest test/test_uploader.rb

require "minitest/autorun"
require "json"
require "socket"
require "timeout"

require "restless"

class TestUploader < Minitest::Test
  # Holds every upload until released, so the cap can be observed.
  class Gated
    attr_reader :max_concurrent

    def initialize
      @lock = Mutex.new
      @gate = Queue.new
      @sizes = []
      @current = 0
      @max_concurrent = 0
    end

    def call(_url, _headers, body)
      @lock.synchronize do
        @sizes << JSON.parse(body).length
        @current += 1
        @max_concurrent = [@max_concurrent, @current].max
      end
      @gate.pop
      @lock.synchronize { @current -= 1 }
      [202, "{}"]
    end

    def release(count)
      count.times { @gate << :go }
    end

    def sizes
      @lock.synchronize { @sizes.dup }
    end
  end

  def setup
    # BATCH-008 would otherwise drop every capture: this file IS a test run.
    ENV["RESTLESS_SETUP_MODE"] = "1"
  end

  def teardown
    ENV.delete("RESTLESS_SETUP_MODE")
  end

  def with_env(vars)
    previous = vars.keys.map { |k| [k, ENV[k]] }
    vars.each { |k, v| ENV[k] = v }
    yield
  ensure
    previous.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
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

  def wait_until(seconds = 2)
    deadline = Time.now + seconds
    sleep(0.005) until yield || Time.now > deadline
  end

  # A transport that answers each call with the next step: a response triple,
  # or an exception to raise. The last step repeats.
  def scripted(*steps)
    bodies = []
    lock = Mutex.new
    transport = lambda do |_url, _headers, body|
      step = lock.synchronize do
        bodies << body
        steps[[bodies.length, steps.length].min - 1]
      end
      raise step if step.is_a?(Exception)

      step
    end
    [transport, bodies]
  end

  def local_uploader(transport, delays = [])
    Restless::Uploader.new(api_key: "k", base_url: "http://localhost:3003",
                           transport: transport, sleeper: ->(s) { delays << s })
  end

  OK = [202, "{}"].freeze

  def refused(status, retry_after = "0")
    [status, "busy", retry_after ? { "Retry-After" => retry_after } : {}]
  end

  # BATCH-009, BATCH-010.
  def test_never_more_than_four_in_flight_and_the_backlog_goes_100_at_a_time
    with_env("RESTLESS_ENV" => "production") do
      gated = Gated.new
      uploader = Restless::Uploader.new(api_key: "k", base_url: "https://remote.example",
                                        transport: gated)
      300.times { |i| uploader.push(capture(i)) }
      wait_until { gated.sizes.length >= 4 }
      sleep(0.05)
      assert_equal [10, 10, 10, 10], gated.sizes

      # Each freed slot takes up to 100 of what queued behind the cap.
      gated.release(4)
      wait_until { gated.sizes.length >= 7 }
      sleep(0.05)
      assert_equal [60, 100, 100], gated.sizes.drop(4).sort

      gated.release(1000)
      uploader.flush
      assert_equal 300, gated.sizes.sum
      assert_operator gated.max_concurrent, :<=, Restless::Uploader::MAX_IN_FLIGHT
    end
  end

  # BATCH-005. Flush drains a full queue, never past the cap or 100 per upload.
  def test_flush_drains_the_whole_queue_within_the_cap
    with_env("RESTLESS_ENV" => "production") do
      lock = Mutex.new
      sizes = []
      current = 0
      peak = 0
      transport = lambda do |_url, _headers, body|
        lock.synchronize do
          sizes << JSON.parse(body).length
          current += 1
          peak = [peak, current].max
        end
        sleep(0.01)
        lock.synchronize { current -= 1 }
        OK
      end
      uploader = Restless::Uploader.new(api_key: "k", base_url: "https://remote.example",
                                        transport: transport)
      queue = uploader.instance_variable_get(:@queue)
      Restless::Uploader::MAX_QUEUE.times { |i| queue << capture(i) }
      uploader.flush

      assert_equal Restless::Uploader::MAX_QUEUE, sizes.sum
      assert_equal 10, sizes.length
      assert_operator peak, :<=, Restless::Uploader::MAX_IN_FLIGHT
      assert_empty uploader.instance_variable_get(:@queue)
    end
  end

  # WIRE-026.
  def test_retries_503_and_429_with_the_same_body
    transport, bodies = scripted(refused(503), refused(429), OK)
    uploader = local_uploader(transport)
    uploader.push(capture(1))
    uploader.flush

    assert_equal 3, bodies.length
    assert_equal 1, bodies.uniq.length
  end

  # WIRE-026: at most 2 retries.
  def test_gives_up_on_a_refused_upload_after_two_retries
    transport, bodies = scripted(refused(503))
    uploader = local_uploader(transport)
    uploader.push(capture(1))
    uploader.flush

    assert_equal 3, bodies.length
  end

  # WIRE-027, WIRE-028: anything the ingest may have stored is never resent.
  def test_does_not_retry_what_the_ingest_may_have_stored
    {
      "a 502" => refused(502),
      "a 504" => refused(504),
      "a 500" => [500, "boom", {}],
      "a read timeout" => Net::ReadTimeout.new,
      "an overall timeout" => Timeout::Error.new("execution expired"),
      "a reset after send" => Errno::ECONNRESET.new,
      "a closed connection" => EOFError.new
    }.each do |label, step|
      transport, bodies = scripted(step, OK)
      uploader = local_uploader(transport)
      uploader.push(capture(1))
      uploader.flush

      assert_equal 1, bodies.length, "#{label} should not be retried"
    end
  end

  # WIRE-026: a connection that never reached the ingest MAY be retried.
  def test_retries_a_connection_that_never_reached_the_ingest
    [Errno::ECONNREFUSED.new, SocketError.new("getaddrinfo: nodename nor servname")].each do |error|
      delays = []
      transport, bodies = scripted(error, OK)
      uploader = local_uploader(transport, delays)
      uploader.push(capture(1))
      uploader.flush

      assert_equal 2, bodies.length, "#{error.class} should be retried"
      assert_equal 1, delays.length
      assert_operator delays.first, :>=, 0.5
      assert_operator delays.first, :<=, 1.5
    end
  end

  # WIRE-026: Retry-After in seconds or as an HTTP date, capped at 10 s.
  def test_retry_after_is_honoured_and_capped
    future = (Time.now + 5).httpdate
    delays = []
    transport, = scripted(refused(503, "3"), refused(429, future), OK)
    uploader = local_uploader(transport, delays)
    uploader.push(capture(1))
    uploader.flush

    assert_in_delta 3.0, delays[0], 0.001
    assert_in_delta 5.0, delays[1], 1.1

    delays = []
    transport, = scripted(refused(503, "120"), OK)
    uploader = local_uploader(transport, delays)
    uploader.push(capture(1))
    uploader.flush
    assert_equal [Restless::Uploader::MAX_RETRY_DELAY_S], delays
  end

  # WIRE-026: no usable Retry-After falls back to jittered backoff from 1 s.
  def test_backoff_without_retry_after_is_jittered_exponential
    delays = []
    transport, = scripted(refused(503, nil), refused(503, "soon"), OK)
    uploader = local_uploader(transport, delays)
    uploader.push(capture(1))
    uploader.flush

    assert_equal 2, delays.length
    assert_operator delays[0], :>=, 0.5
    assert_operator delays[0], :<=, 1.5
    assert_operator delays[1], :>=, 1.0
    assert_operator delays[1], :<=, 3.0
  end

  # BATCH-005: flush waits for retries, not just the first attempt.
  def test_flush_waits_for_a_retry_in_progress
    transport, bodies = scripted(refused(503), OK)
    uploader = Restless::Uploader.new(api_key: "k", base_url: "http://localhost:3003",
                                      transport: transport, sleeper: ->(_s) { sleep(0.2) })
    uploader.push(capture(1))
    uploader.flush

    assert_equal 2, bodies.length
  end

  # SAFETY-001, SAFETY-004.
  def test_a_raising_transport_never_reaches_the_caller
    transport, bodies = scripted(RuntimeError.new("transport exploded"))
    uploader = local_uploader(transport)

    assert_nil uploader.push(capture(1))
    assert_nil uploader.flush
    assert_equal 1, bodies.length
  end

  # A real socket, so the exception Net::HTTP actually raises is what gets
  # classified, not a stand-in.
  def test_a_real_refused_connection_is_retried
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    server.close

    delays = []
    uploader = Restless::Uploader.new(api_key: "k", base_url: "http://127.0.0.1:#{port}",
                                      sleeper: ->(s) { delays << s })
    uploader.push(capture(1))
    uploader.flush

    assert_equal Restless::Uploader::MAX_RETRIES, delays.length
  end

  def test_a_real_503_with_retry_after_is_retried
    port, bodies, server = serve(
      "HTTP/1.1 503 Service Unavailable\r\nRetry-After: 0\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
      "HTTP/1.1 202 Accepted\r\nContent-Type: application/json\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}"
    )
    delays = []
    uploader = Restless::Uploader.new(api_key: "k", base_url: "http://127.0.0.1:#{port}",
                                      sleeper: ->(s) { delays << s })
    uploader.push(capture(1))
    uploader.flush

    assert_equal 2, bodies.length
    assert_equal [0.0], delays
  ensure
    server&.close
  end

  # WIRE-028: a hung ingest is abandoned, and the abandoned upload is not resent.
  def test_a_real_upload_that_hangs_times_out_and_is_not_retried
    port, bodies, server = serve(nil, nil)
    uploader = Restless::Uploader.new(api_key: "k", base_url: "http://127.0.0.1:#{port}",
                                      sleeper: ->(_s) {})
    started = Time.now
    with_upload_timeout(0.3) do
      uploader.push(capture(1))
      uploader.flush
    end

    assert_operator Time.now - started, :<, 3
    assert_equal 1, bodies.length
  ensure
    server&.close
  end

  # Puma and Unicorn fork after boot. A child must not inherit the parent's
  # queue or its slot count, whose threads do not exist in the child.
  def test_a_forked_child_starts_clean
    skip "fork is not available here" unless Process.respond_to?(:fork)

    with_env("RESTLESS_ENV" => "production") do
      sizes = []
      transport = lambda do |_url, _headers, body|
        sizes << JSON.parse(body).length
        OK
      end
      uploader = Restless::Uploader.new(api_key: "k", base_url: "https://remote.example",
                                        transport: transport)
      3.times { |i| uploader.push(capture(i)) }
      uploader.instance_variable_set(:@active, Restless::Uploader::MAX_IN_FLIGHT)

      pid = fork do
        code = begin
          Timeout.timeout(5) do
            10.times { |i| uploader.push(capture(100 + i)) }
            uploader.flush
          end
          sizes == [10] ? 0 : 1
        rescue Timeout::Error
          2
        end
        exit!(code)
      end
      Process.wait(pid)

      assert_equal 0, $?.exitstatus
      uploader.instance_variable_set(:@active, 0)
    end
  end

  private

  # A one-shot HTTP server answering each connection with the next response;
  # nil holds that connection open without answering.
  def serve(*responses)
    server = TCPServer.new("127.0.0.1", 0)
    bodies = []
    held = []
    Thread.new do
      responses.each do |response|
        client = server.accept
        length = 0
        while (line = client.gets) && line != "\r\n"
          name, value = line.split(":", 2)
          length = value.to_i if name.casecmp("content-length").zero?
        end
        bodies << client.read(length)
        if response
          client.write(response)
          client.close
        else
          held << client
        end
      end
    rescue IOError, SystemCallError
      nil
    end
    [server.addr[1], bodies, server]
  end

  def with_upload_timeout(seconds)
    original = Restless::Uploader::HTTP_TIMEOUT_S
    swap_timeout(seconds)
    yield
  ensure
    swap_timeout(original)
  end

  def swap_timeout(value)
    Restless::Uploader.send(:remove_const, :HTTP_TIMEOUT_S)
    Restless::Uploader.const_set(:HTTP_TIMEOUT_S, value)
  end
end
