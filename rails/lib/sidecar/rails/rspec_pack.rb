# frozen_string_literal: true

module Sidecar
  module Rails
    # RSpec, which is not Rails' default test framework — hence its own pack.
    #
    # This is where every RSpec layout convention lives. Core keeps one sentence
    # of mechanism (apply the first matching rule, expand its replacements, keep
    # the ones on disk); a Minitest or `test/` project restates the table below
    # rather than asking core for a hook.
    RSpecPack = {
      sensors: [
        {
          id: :rspec_smoke,
          name: "Tests: Smoke",
          command: "RAILS_ENV=test bundle exec rspec spec/smoke --format progress",
          tier: :fast, kind: :computational, group: :test,
          scope: %w[app/**/*.rb lib/**/*.rb spec/**/*.rb],
          needs: [ :database ],
          guidance: "A smoke test is failing"
        },
        {
          id: :targeted_specs,
          name: "Tests: Targeted",
          command: "RAILS_ENV=test bundle exec rspec --format progress {files}",
          ci: false, tier: :fast, kind: :computational, group: :test,
          scope: %w[app/**/*.rb lib/**/*.rb packs/**/*.rb spec/**/*.rb],
          needs: [ :database ],
          # Full-path regexes rather than the bare prefixes they replace, which
          # read worse but are what makes packs and engines work with no extra
          # rules. Worked example:
          #
          #   packs/prospects/app/services/x.rb
          #     matches (\A|/)app/  at the "/app/" boundary, \1 = "/"
          #     becomes packs/prospects/spec/services/x_spec.rb
          #
          # First match wins, which is load-bearing: app/lib/foo.rb matches both
          # the app/ and lib/ rules, and firing both would produce the correct
          # spec/lib/foo_spec.rb alongside a nonsense app/spec/lib/foo_spec.rb.
          #
          # The replacement is always a list because the relationship genuinely
          # is one-to-many — a model plausibly owes a model spec and a request
          # spec. The shipped default stays one-to-one so nobody pays for that
          # until they opt in.
          handler: Sidecar::Handlers::TargetedSpecs.new(
            rules: {
              /_spec\.rb\z/ => [ '\0' ],
              %r{(\A|/)app/(.*)\.rb\z} => [ '\1spec/\2_spec.rb' ],
              %r{(\A|/)lib/(.*)\.rb\z} => [ '\1spec/lib/\2_spec.rb' ]
            }
          ),
          guidance: "The spec covering a file you changed is failing"
        },
        {
          id: :rspec_full,
          name: "Tests: Full Suite",
          command: "RAILS_ENV=test bundle exec rspec spec/ --format progress",
          tier: :slow, kind: :computational, group: :test,
          scope: %w[app/**/*.rb lib/**/*.rb spec/**/*.rb],
          needs: [ :database ]
        }
      ].freeze
    }.freeze
  end
end
