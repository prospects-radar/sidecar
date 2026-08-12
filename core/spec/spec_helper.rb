# frozen_string_literal: true

# Deliberately does not require "sidecar" here. Each spec requires exactly the
# file it exercises, which keeps the Rails-free enforcement honest: a spec that
# only passes because spec_helper pulled in the whole tree is not evidence that
# the file under test stands alone.

require_relative "support/repo"

RSpec.configure do |config|
  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  config.shared_context_metadata_behavior = :apply_to_host_groups
  config.disable_monkey_patching!
  config.order = :random
  Kernel.srand config.seed

  config.include Sidecar::SpecSupport::Repo
end
