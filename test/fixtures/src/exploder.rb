# frozen_string_literal: true

# Fixture for test/test_stack_frames.rb. Lives under a `src/` directory on
# purpose so FP-042's project-relative rewrite has something to bite on.
module Exploder
  # The innermost frame: what FP-043 says the fingerprint must key on.
  def self.detonate
    raise "the widget frobnicator is on fire"
  end

  def self.middle
    detonate
  end

  def self.outer
    middle
  end

  def self.from_a_block
    [1].each { |_| detonate }
  end

  def self.from_a_nested_block
    [1].each { |_| [2].each { |_| detonate } }
  end
end
