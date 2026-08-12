# frozen_string_literal: true

require_relative "lib/sidecar/rails/version"

Gem::Specification.new do |spec|
  spec.name = "sidecar-rails"
  spec.version = Sidecar::Rails::VERSION
  spec.authors = [ "Bert Hajee" ]
  spec.email = [ "bert.hajee@enterprisemodules.com" ]
  spec.license = "MIT"

  spec.summary = "The sensor pack a Rails codebase would otherwise write identically."
  spec.description = <<~TEXT
    Declarations only: the sensors and defaults every Rails project would write the same way,
    shipped so it does not have to. No control flow, no IO, no process invocation, and no
    Railtie — nothing here runs during Rails boot, because nothing in the sidecar's path goes
    through Rails boot. It ships strings naming Rails commands and never loads Rails itself.
  TEXT

  spec.homepage = "https://github.com/prospects-radar/sidecar"
  spec.metadata["source_code_uri"] = "https://github.com/prospects-radar/sidecar"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.required_ruby_version = ">= 4.0"

  spec.files = Dir[ "lib/**/*.rb", "LICENSE", "README.md" ]
  spec.require_paths = [ "lib" ]

  # A loose range rather than a pin to VERSION. Note this constraint is never
  # exercised: the development Gemfile resolves core by path, and the one consumer
  # sources both gems from the same branch. It documents the relationship; the
  # consumer's contract spec is what actually guards it.
  spec.add_dependency "sidecar-core", "~> 0.1"

  # Deliberately no dependency on `rails`. This gem names Rails commands in strings
  # and never loads them.
end
