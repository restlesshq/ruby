# frozen_string_literal: true

# The Ruby dialect of FP-043/FP-044/FP-045.
#
#     ruby -Ilib -Itest test/test_stack_frames.rb
#
# FP-046 makes the shared `fp/stack-*` vectors reference-dialect only: they
# feed a v8-shaped stack into `fingerprint`, and the conformance driver reports
# them as `unsupported` rather than guessing. That is exactly why this file has
# to exist -- it is the ONLY coverage of Ruby stack parsing.
#
# Everything here uses a REAL raised exception where the property under test is
# about Ruby's runtime (frame order, frame text), and a synthetic backtrace
# only where the property is about the skip list.

require "minitest/autorun"

require "restless/stack_frames"
require "restless/fingerprint"

require_relative "fixtures/src/exploder"

class TestStackFrames < Minitest::Test
  FIXTURE = File.expand_path("fixtures/src/exploder.rb", __dir__)

  def raised
    Exploder.outer
    flunk "expected a raise"
  rescue StandardError => e
    e
  end

  # FP-043 is a SEMANTIC requirement, not a positional one: v8 puts the throw
  # site first and a Python traceback puts it last. Verify Ruby's direction
  # empirically rather than assuming it.
  def test_backtrace_is_innermost_first
    trace = raised.backtrace
    throw_site = trace.index { |line| line =~ /:in [`']detonate'\z/ }
    caller_site = trace.index { |line| line =~ /:in [`']outer'\z/ }

    assert_equal 0, throw_site,
                 "Ruby backtraces are expected to be innermost-FIRST (like v8 and " \
                 "Go, unlike a Python traceback). If this ever changes, " \
                 "StackFrames.top_user_frame must walk the other way or every 500 " \
                 "collapses into one fingerprint group."
    assert_operator throw_site, :<, caller_site
  end

  # FP-043. The frame nearest the throw site, not the entry point. Getting the
  # direction wrong collapses every 500 in the process into one fingerprint
  # group, which defeats the strategy entirely.
  def test_top_user_frame_is_the_throw_site
    frame = Restless::StackFrames.from_exception(raised)
    refute_nil frame
    assert_equal "detonate", frame[:fn]
  end

  # FP-042, verified against the same helper the shared `projectRelative`
  # vectors exercise, so this test does not depend on the checkout path.
  def test_frame_file_is_project_relative
    frame = Restless::StackFrames.from_exception(raised)
    assert_equal Restless::Fingerprint.project_relative(FIXTURE), frame[:file]
    assert frame[:file].end_with?("src/exploder.rb"), frame[:file]
  end

  # FP-040. The whole point: `{status}:{file}:{fn}`, no line number (FP-041).
  def test_stack_strategy_key
    frame = Restless::StackFrames.from_exception(raised)
    result = Restless::Fingerprint.compute(status: 500, method: "GET",
                                           route: "/crash", stack_frame: frame)
    assert_equal "stack", result.strategy
    assert_equal "500:#{frame[:file]}:detonate", result.key
    refute_match(/:\d+/, result.key.sub(/\A500:/, ""),
                 "FP-041: a line number in the key would split a group on a " \
                 "cosmetic edit")
  end

  # A block raising still keys on something stable. The `(N levels)` count is
  # closer to a line number than to an identity, so it is normalized away.
  def test_block_frames_are_normalized
    error = begin
      Exploder.from_a_nested_block
    rescue StandardError => e
      e
    end
    frame = Restless::StackFrames.from_exception(error)
    assert_equal "detonate", frame[:fn]

    parsed = Restless::StackFrames.parse_frame("/a/src/x.rb:9:in `block (3 levels) in run'")
    assert_equal "block in run", parsed[:fn]
    assert_equal "/a/src/x.rb", parsed[:file]
  end

  # FP-044. The skip list is matched by FILE PATH, never by module or class
  # name: a name check would also skip a customer's own Restless-flavoured
  # code, and would fail to skip this gem when vendored under another
  # constant.
  def test_skips_sdk_gem_and_stdlib_frames
    sdk_file = File.join(Restless::StackFrames::SDK_DIR, "restless", "rack.rb")
    stdlib_file = File.join(Restless::StackFrames::STDLIB_DIRS.first, "net", "http.rb")

    backtrace = [
      "#{stdlib_file}:1000:in `request'",
      "/usr/local/lib/ruby/gems/3.2.0/gems/puma-6.4.0/lib/puma/server.rb:12:in `handle'",
      "#{sdk_file}:120:in `call'",
      "/srv/myapp/app/controllers/pets_controller.rb:31:in `show'"
    ]
    frame = Restless::StackFrames.top_user_frame(backtrace)
    assert_equal "show", frame[:fn]
    # FP-042 takes the LAST project dir, so a Rails `app/controllers` layout
    # keys on `controllers/...` rather than carrying `app/` along.
    assert_equal "controllers/pets_controller.rb", frame[:file]
  end

  # FP-045.
  def test_anonymous_when_the_method_cannot_be_determined
    frame = Restless::StackFrames.top_user_frame(["/srv/app/src/boot.rb:4"])
    assert_equal "anonymous", frame[:fn]
    assert_equal "src/boot.rb", frame[:file]
  end

  # Ruby 3.4 changed the frame label quoting from `method' to 'method'. Both
  # dialects have to parse, because this gem supports 2.7 through current.
  def test_parses_both_quote_styles
    old = Restless::StackFrames.parse_frame("/a/src/x.rb:9:in `run'")
    new = Restless::StackFrames.parse_frame("/a/src/x.rb:9:in 'Klass#run'")
    assert_equal "run", old[:fn]
    assert_equal "Klass#run", new[:fn]
  end

  def test_no_user_frame_returns_nil
    only_vendor = ["/usr/local/lib/ruby/gems/3.2.0/gems/rack-3.0.0/lib/rack.rb:1:in `call'"]
    assert_nil Restless::StackFrames.top_user_frame(only_vendor)
    assert_nil Restless::StackFrames.top_user_frame(nil)
  end

  # FP-042. The ONLY thing project_relative exists to do: the same source file
  # keys identically wherever it is deployed. The LAST project dir wins, so a
  # deployment root that is itself named after one (Docker `WORKDIR /app`,
  # Heroku) does not survive into the key.
  #
  # A first-match rule resolves the middle two to `app/src/db/users.rb` and
  # makes production disagree with a laptop for the same file, which is what
  # this used to do.
  def test_project_relative_is_machine_independent
    laptop = Restless::Fingerprint.project_relative("/Users/dev/proj/src/db/users.rb")
    docker = Restless::Fingerprint.project_relative("/app/src/db/users.rb")
    render = Restless::Fingerprint.project_relative("/opt/render/project/src/db/users.rb")

    assert_equal "src/db/users.rb", laptop
    assert_equal laptop, docker,
                 "A Docker WORKDIR /app root must not change the fingerprint"
    assert_equal laptop, render
  end

  # FP-042's accepted trade: a nested layout collapses to the LAST marker
  # rather than keeping the intermediate path. Rarer than an /app root, and
  # still machine-independent, which is the property that matters.
  def test_project_relative_takes_the_last_marker
    assert_equal "src/c.rb", Restless::Fingerprint.project_relative("/a/src/b/src/c.rb")
    # No marker at all: the last two components.
    assert_equal "place/thing.rb", Restless::Fingerprint.project_relative("/opt/weird/place/thing.rb")
    # A marker as the FINAL component is a file, not a directory, so the scan
    # stops before it.
    assert_equal "proj/src", Restless::Fingerprint.project_relative("/home/proj/src")
    assert_equal "thing.rb", Restless::Fingerprint.project_relative("thing.rb")
    assert_equal "/thing.rb", Restless::Fingerprint.project_relative("/thing.rb")
    # `split("/", -1)`: without the negative limit Ruby drops the trailing
    # empty field, the scan misses `src`, and this returns "proj/src".
    assert_equal "src/", Restless::Fingerprint.project_relative("/home/proj/src/")
  end
end
