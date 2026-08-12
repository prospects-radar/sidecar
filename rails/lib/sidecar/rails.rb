# frozen_string_literal: true

require "sidecar"

require_relative "rails/version"
require_relative "rails/pack"
require_relative "rails/rspec_pack"
require_relative "rails/importmap_pack"

# The sensor pack a Rails codebase would otherwise write identically.
#
# Declarations only. Everything here is a frozen literal: no methods, no control
# flow, no IO, no process invocation, and no Railtie. A Railtie runs during Rails
# boot, and nothing in the sidecar's path goes through Rails boot — which is why
# the consuming Gemfile carries `require: false` and this file is loaded
# explicitly by the one file that names the packs.
#
# Split three ways rather than one, because the honest contents of "the Rails
# pack" are a Rails-with-RSpec-and-parallel_tests-on-importmaps assumption. RSpec
# is not Rails' default test framework, and a Rails 8 app on esbuild has no
# importmap. Named sub-packs buy that honesty for one extra `use` line, where a
# third gem would cost a third gemspec, a third CI lane and a version matrix.
module Sidecar
  module Rails
  end
end
