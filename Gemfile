# frozen_string_literal: true

source "https://rubygems.org"

# A development shell for the whole repo: lets you run rubocop across both gems
# and open a console with either loaded. CI does not use this file — each job
# installs its gem's own Gemfile, which is what proves the gems stand alone.
gem "sidecar-core", path: "core"
gem "sidecar-rails", path: "rails"

group :development, :test do
  gem "rspec", "~> 3.13"
  gem "rubocop", "~> 1.75", require: false
  gem "json_schemer", "~> 2.4"
end
