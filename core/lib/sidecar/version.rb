# frozen_string_literal: true

module Sidecar
  # Both gems ship the same version and move together by convention, not by
  # mechanism. The consuming project's contract spec is what actually proves the
  # pair still agree; the `~> 0.1` range in sidecar-rails.gemspec is documentation.
  VERSION = "0.1.0"
end
