# frozen_string_literal: true

module Sidecar
  module Rails
    # Its own pack because a Rails 8 app on esbuild has no importmap, and a base
    # pack shipping this would hand those projects a sensor for a file that does
    # not exist.
    ImportmapPack = {
      sensors: [
        {
          id: :importmap_audit,
          name: "Security: Importmap",
          command: "bin/importmap audit",
          tier: :fast, kind: :computational, group: :security,
          scope: %w[config/importmap.rb vendor/javascript/**],
          guidance: "Run `bin/importmap audit` for the advisories"
        }
      ].freeze
    }.freeze
  end
end
