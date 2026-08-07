# frozen_string_literal: true

# Every test in one command, with nothing but a Ruby install:
#
#     ruby -Ilib -Itest test/all.rb

require_relative "test_vectors"
require_relative "test_stack_frames"
require_relative "test_middleware"
