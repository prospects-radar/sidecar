# frozen_string_literal: true

require_relative "lib/sidecar/version"

Gem::Specification.new do |spec|
  spec.name = "sidecar-core"
  spec.version = Sidecar::VERSION
  spec.authors = [ "Bert Hajee" ]
  spec.email = [ "bert.hajee@enterprisemodules.com" ]
  spec.license = "MIT"

  spec.summary = "A continuous readout of your existing quality tools, narrowed to the lines you just changed."
  spec.description = <<~TEXT
    Sidecar runs the checks a project already has, keeps only the findings sitting on lines
    that just changed, and renders them as a board and a one-line digest. It owns no rules
    and no analysis of its own: every finding comes from a tool the project already installed.
    The core takes no Rails dependency and boots nothing, so a pass stays cheap enough to run
    on every edit.
  TEXT

  spec.homepage = "https://github.com/prospects-radar/sidecar"
  spec.metadata["source_code_uri"] = "https://github.com/prospects-radar/sidecar"
  spec.metadata["rubygems_mfa_required"] = "true"

  # 4.0 is both the declared floor and the tested one. CI runs a single Ruby, so a
  # lower claim would be untrue about the evidence. Loosening later costs one line.
  spec.required_ruby_version = ">= 4.0"

  # spec/ is deliberately absent: the temp-repo helper is not a supported surface.
  # schema/ and compose/ ship because both are resolved __dir__-relative at runtime.
  spec.files = Dir[
    "lib/**/*.rb",
    "exe/*",
    "schema/*.json",
    "compose/*.yml",
    "LICENSE",
    "README.md"
  ]
  spec.bindir = "exe"
  spec.executables = [ "sidecar" ]
  spec.require_paths = [ "lib" ]

  # No runtime dependencies, on purpose. open3, English, set, json, fileutils,
  # shellwords, etc, are all stdlib. This is what makes "boots nothing" checkable
  # rather than aspirational, and core/spec asserts this list stays empty.
end
