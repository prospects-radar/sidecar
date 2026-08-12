# frozen_string_literal: true

module Sidecar
  module Rails
    # The base pack: what a Rails codebase runs regardless of its test framework
    # or its asset pipeline.
    #
    # `rubocop` sits here despite being Ruby rather than Rails. That is the
    # accepted cost of two gems rather than three: a Ruby-tools pack would be a
    # third gemspec and a third CI lane for one sensor.
    Pack = {
      sensors: [
        {
          id: :db_setup,
          name: "Database: Setup",
          # Vanilla on purpose. A project on parallel_tests overrides this, which
          # keeps the pack honest about what it assumes rather than shipping
          # someone else's setup as though it were the default.
          command: "bin/rails db:test:prepare",
          sidecar: false, tier: :slow, kind: :computational, group: :setup,
          needs: [ :database ]
        },
        {
          id: :rubocop,
          name: "Quality: RuboCop",
          command: "bundle exec rubocop --format progress",
          tier: :fast, kind: :computational, group: :lint,
          scope: %w[app/**/*.rb lib/**/*.rb config/**/*.rb spec/**/*.rb packs/**/*.rb],
          handler: Sidecar::Handlers::Rubocop.new,
          guidance: "Run `bundle exec rubocop -a` to autocorrect"
        },
        {
          id: :brakeman,
          name: "Security: Brakeman",
          command: "bin/brakeman --no-pager --quiet",
          tier: :fast, kind: :computational, group: :security,
          scope: %w[app/**/*.rb lib/**/*.rb],
          guidance: "Run `bin/brakeman --no-pager` for the full report"
        },
        {
          id: :assets_precompile,
          name: "Assets: Precompile",
          command: "RAILS_ENV=test bin/rails assets:precompile",
          sidecar: false, tier: :slow, kind: :computational, group: :build
        }
      ].freeze,

      # Suggested settings, never applied silently. `provides` is deliberately
      # absent: a pack cannot see the machine, and one asserting node would hand
      # half its consumers a failing sensor where the honest answer is
      # unavailable.
      defaults: {
        workdir: "/rails",
        prepare_command: "bin/rails db:test:prepare",
        artifacts: "tmp/sidecar"
      }.freeze
    }.freeze
  end
end
