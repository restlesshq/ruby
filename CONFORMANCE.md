# Conformance

| | |
|---|---|
| **Spec version** | 1.0.0 |
| **Level** | L2 (core + batching, caches, injection, safety) |
| **Reference** | `restlesshq/node` (`@restlessai/sdk`) |
| **Driver** | `ruby exe/restless-conformance` |

Declared in `lib/restless/version.rb` (META-001).

## Verifying

The harness and vectors live in the reference SDK, so the commands below
assume it is checked out as a sibling (`../node-sdk`), which is how
`setup.sh` in the install repo arranges things. The vectors in `spec/` here
are a pinned copy, so `ruby -Ilib -Itest test/all.rb` alone works without it.


```sh
# in-process, no Node and no bundler needed
ruby -Ilib -Itest test/all.rb

# the shared cross-language harness
node ../node-sdk/spec/harness/run-vectors.mjs -- ruby exe/restless-conformance

# differential fuzz against the reference implementation
node ../node-sdk/spec/harness/fuzz.mjs \
  --ref  "node ../node-sdk/spec/driver/.build/node.js" \
  --test "ruby exe/restless-conformance" \
  --iterations 8000 --seed 24301
```

Current status: **208 vectors, 199 passed, 0 failed, 9 skipped.** Zero
divergence across 34,918 fuzz comparisons on five seeds (24301, 1, 4242,
99991, 777).

The 9 skips are cases outside this implementation's dialect, not gaps:

- 8 `fp/stack-*` cases feed a v8-shaped stack into `fingerprint`. FP-044
  makes frame parsing per-language and FP-046 requires the driver to say so
  rather than guess. Covered natively in `test/test_stack_frames.rb`. This
  includes `fp/stack-not-used-for-4xx`, where the stack is never consulted:
  the driver declares the dialect on the INPUT rather than on whether the
  strategy happens to fire, which is what the Python and Go drivers do too.
- 1 `redactBody/lone-surrogate` case. See the exemption below.

## Ruby-specific decisions

Each of these is a place where the obvious Ruby code silently disagrees with
the reference. They are the reason this SDK is byte-compatible.

| Contract | What Ruby needs |
|---|---|
| PRIM-002 | `WS` is enumerated as code points in `text.rb`. Ruby's `\s` is ASCII-only and NARROWER than the contract's set: no NBSP, no Zs category, no LS/PS/ZWNBSP. |
| PRIM-003 | **Ruby's `\b` is Unicode-aware even though its `\w` is not.** Onigmo defines the boundary against the Unicode word property, so `\b[\w-]*[0-9][\w-]*\b` leaves `éa1` untouched where JavaScript, Go and Python-with-`re.ASCII` all strip the `a1`. `Fingerprint.strip_digit_words` applies that one regex to the UTF-8 BYTES, which restores JavaScript's semantics exactly (every non-ASCII character becomes a run of non-word bytes, which is what a non-`u` JS regex sees in UTF-16 too). The pattern can only match ASCII bytes, so the result is still well-formed UTF-8. |
| PRIM-005 | `\A...\z` everywhere, never `^...$`. Ruby's `$` also matches before a trailing newline, so a route segment of `"5\n"` would normalize to `:id` here and not in JavaScript. |
| PRIM-006 | Hex digits validated explicitly against `[0-9a-fA-F]`. `String#to_i(16)` returns 0 for garbage rather than failing, so `%zz` would silently decode as a NUL byte. |
| PRIM-010 vs PRIM-011 | `String#length` is code points (what REDACT-002 and MASK-006 want) and `String#bytesize` is UTF-8 bytes (what HAR-010 and REDACT-030 want). They are never interchangeable. |
| PRIM-013 | `Text.to_utf8` scrubs invalid bytes to U+FFFD instead of raising. Rack hands out header and body strings tagged UTF-8 that are not valid UTF-8. It also DECODES a BINARY string rather than transcoding it: `IO#read(n)` always returns ASCII-8BIT and the Rack spec requires `rack.input` to be binary, and Ruby's BINARY-to-UTF-8 transcode has no mapping above `0x7F`, so `encode` turns every byte of every multi-byte character into its own U+FFFD. That corrupted every non-ASCII body the SDK captured and was a second redaction bypass on top of REDACT-010, since a mangled key no longer matches the denylist. |
| PRIM-020 | `String#downcase` is FULL case mapping and is used unmodified everywhere, including for REDACT-010 names. U+0130 becomes two code points (matching JS and Python, unlike Go's simple mapping) and U+212A KELVIN SIGN becomes `k`. It is not `casefold` and applies no locale tailoring. The one thing it does not do is the Final_Sigma contextual rule that `String.prototype.toLowerCase` applies (word-final Σ to ς rather than σ), and per the PRIM-021 note that is **not required**: nothing in the contract can observe it, because Greek is outside `WORD` so FP-020 step 6 replaces both sigma forms with a space before either reaches a token, and the REDACT-010 denylists are ASCII. An earlier `\p{Cased}` / `\p{Case_Ignorable}` implementation of the rule was removed as untestable. |
| PRIM-030..032 | Ruby's `JSON.generate` is already compact, insertion-ordered and literal-UTF-8, and does not HTML-escape - so the `<REDACTED:...>` sentinel the dashboard pattern-matches on survives. Verified byte-identical to `JSON.stringify` for control characters, quotes, backslashes and astral characters. |
| PRIM-040 | Hand-built with `strftime("%Y-%m-%dT%H:%M:%S.%LZ")`. `Time#iso8601` needs `require "time"` plus an explicit fractional-digit count and emits `+00:00` unless the receiver is already UTC. |
| REDACT-010 | Name normalization uses **full Unicode** lowercase (PRIM-020), not an ASCII fold, and this is a security requirement rather than a cosmetic one. Normalization decides whether a value is redacted, so it must fold more aggressively rather than less: a header `x-api-Key` or a body key `toKen` whose `K` is U+212A KELVIN SIGN lowercases to a denylisted name and must be redacted. A hand-written ASCII-only fold is the easy mistake here, and it ships such values to the dashboard in plaintext. Pinned by `redactHeaders/unicode-fold-kelvin`, `redactBody/unicode-fold-kelvin` and `test_middleware.rb#test_kelvin_sign_does_not_bypass_the_denylist`. |
| REDACT-016 | An explicit code-point scan, never `^(\S+)(\s+)(\S.*)$`. Ruby's `.` excludes only LF while JavaScript's also excludes CR, LS and PS, so a credential containing a stray CR would take the scheme-preserving branch here and the redact-whole branch there. |
| REDACT-025 | `split("&", -1)` and `split("/", -1)`. Ruby drops trailing empty fields without the negative limit, so `?a=1&` would come back as `?a=1` and `/users/` would lose its trailing segment. |
| REDACT-028 | The unreserved set is spelled out. `CGI.escape` turns a space into `+` and escapes `~`; `URI.encode_www_form_component` differs again. |
| REDACT-029 | `bytes.pack("C*").force_encoding("UTF-8").scrub` is byte-identical to Node's `Buffer#toString("utf8")`, including the maximal-subpart replacement rule. Verified differentially. |
| FP-020 step 9 | `split(/ /, -1)`, never `split(" ")`. A literal single-space argument triggers Ruby's awk-mode split, which collapses runs and drops leading empties. |
| FP-030 | Hex classes written as `[0-9a-fA-F]` with no `i` flag. Ruby's case-insensitive matching is Unicode case folding, a wider relation than the ASCII-only canonicalization a non-`u` JavaScript regex performs. |
| FP-042 | `project_relative` splits on `/` and scans BACKWARDS from the second-to-last segment, so the LAST project dir wins and a deployment root named `/app` (Docker `WORKDIR`, Heroku) cannot survive into the key. `split("/", -1)`: without the negative limit Ruby drops the trailing empty field, so `/proj/src/` would miss `src` here and match it in JavaScript. |
| FP-047 | `Fingerprint::Result` carries `previous_key`, serialized as `previousKey` and omitted when nil. Set only by the stack strategy, from the shared `fallback_key` helper rather than a second copy of the ladder. `Uploader#distinct_fingerprints` sends both keys; `CaptureEngine#lookup_recovery_for` prefers the current one and falls back, and the Rack middleware calls it instead of the key-only `lookup_recovery`. |
| FP-043 | Ruby's `Exception#backtrace` is innermost-FIRST, like v8 and Go and unlike a Python traceback, so the walk goes forwards. Verified empirically in `test/test_stack_frames.rb` rather than assumed. |
| FP-044 | Frames are `path:line:in \`method'` (`'method'` from Ruby 3.4); both quote styles parse. `block (N levels) in foo` is normalized to `block in foo`, since the nesting count behaves like a line number. Skips are matched by FILE PATH: the SDK's own directory (resolved from `__dir__`), `RbConfig`'s stdlib dirs, `Gem.path`, any `/gems/` segment, and `<internal:` frames. Never by module or class name - a name check would also skip a customer's own Restless-flavoured code and would fail to skip this gem when vendored under another constant. |
| INJECT-005 | `Text.ws_trim`, not `String#strip`. Ruby's strip removes NUL and leaves NBSP; the contract wants exactly the PRIM-002 set. |
| BATCH-003 | The environment indicator is `RESTLESS_ENV`, then `RACK_ENV`, then `RAILS_ENV`. Ruby has three spellings in the wild and no single winner. |
| BATCH-008 | Test detection keys on those same variables being `test`, plus `RSpec::Core`, `Minitest::Test` and `Test::Unit::TestCase` being defined. |
| CACHE-* | Both caches are Mutex-guarded. Puma, Falcon and threaded Unicorn all serve requests on many threads, so an unsynchronized Hash is a real race. |

## Exemption: PRIM-034 (unpaired surrogates)

This SDK claims the **PRIM-035 exemption**, on stronger grounds than Go's.

A Go string merely *replaces* an unpaired surrogate with U+FFFD while
decoding. Ruby is more restrictive in both directions:

- `JSON.parse('"\ud83d"')` **raises** `JSON::ParserError: incomplete
  surrogate pair`. The value never reaches SDK code at all.
- `"\u{d83d}"` is not a legal Ruby literal - the parser rejects it with
  `invalid Unicode codepoint`. `[0xd83d].pack("U")` produces the CESU-8
  bytes `ED A0 BD`, which `String#valid_encoding?` reports as false.

So a Ruby `String` has no representation for the value, and per PRIM-035 the
SDK never raises on such input and substitutes U+FFFD (`Text.to_utf8`).

The conformance driver reports `unsupported` for any input LINE containing a
lone surrogate escape, checked on the raw line **before** parsing, because
the limitation is at the transport layer rather than in redaction - parsing
first would produce a `JSON::ParserError` that looks like a conformance
failure. `test/test_vectors.rb` does the same, swapping each such escape for
an ASCII marker so the vector documents can be read at all, then skipping the
cases that contained one.

## Residual differences, accepted

**Number rendering in a re-serialized body.** REDACT-020 means a body is only
re-serialized when it actually contains a denylisted key. For those bodies,
Ruby preserves int64 exactly where JavaScript silently truncates above 2^53,
and Ruby's `Float#to_s` uses a different exponent form than JavaScript for
very large and very small magnitudes. This matches the Python SDK and is the
behaviour PRIM-033 describes as the *correct* one; the reference is the odd
one out. It is unreachable from the fuzzer, because `JSON.stringify` has
already collapsed such values before the input is generated.
