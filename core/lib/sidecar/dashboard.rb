# frozen_string_literal: true

require_relative "liveness"
require_relative "report"

module Sidecar
  # The human half of the two outputs, reading the same status.json the agent
  # digest is rendered from.
  #
  # Where the digest is red-only and token-capped — an agent pays for every line
  # it reads — this shows the whole board, greens included. A person watching
  # wants to know that twelve things are being checked and eleven are fine, which
  # is exactly the information the digest spends its budget leaving out.
  #
  # Plain redraw rather than a TUI: core has no runtime dependencies, and a
  # curses layer would be the first.
  class Dashboard
    REFRESH_INTERVAL = 2.0

    # Cursor home, then clear. Home first so the repaint starts at the top even
    # on terminals that scroll rather than wipe.
    CLEAR = "\e[H\e[2J"

    ICONS = {
      "green" => "✓",
      "red" => "🔴",
      "running" => "⏳",
      "stale" => "⚠",
      "deferred" => "⏸",
      # Its own mark, not folded into deferred. A resource this location lacks
      # and a tool nobody installed look identical on a board that conflates
      # them, and they have different fixes.
      "unavailable" => "○",
      "error" => "‼"
    }.freeze

    UNKNOWN_ICON = "?"

    # Most urgent first, matching the digest's reading order so the two do not
    # disagree about what matters. Deliberately not the registry's run order,
    # which puts setup first because a database that is not prepared fails
    # everything behind it — a different question from what to read first.
    GROUP_ORDER = %w[test security lint build setup].freeze

    NAME_WIDTH = 24

    def self.read(dir:, now: Time.now)
      status = Liveness.load_status(File.join(dir, Report::STATUS_FILE))
      new(status:, liveness: Liveness.new(status:, now:))
    end

    def initialize(status:, liveness:)
      @status = status
      @liveness = liveness
    end

    def render
      return "#{liveness.headline}\n\n(no pass yet — is the sidecar running?)\n" if sensors.empty?

      [ headline, liveness.headline, *skew_line, "", *groups, "", footer ].compact.join("\n")
    end

    private

    attr_reader :status, :liveness

    def sensors = Array(status && status["sensors"])

    def headline
      counts = sensors.group_by { |sensor| sensor["state"] }.transform_values(&:size)
      summary = ICONS.keys.filter_map { |state| "#{counts[state]} #{state}" if counts[state]&.positive? }

      "Sidecar — #{summary.join(' · ')}"
    end

    # A warning line rather than a refusal: a stale image is one rebuild away.
    def skew_line
      skew = liveness.version_skew
      skew ? [ "⚠ #{skew}" ] : []
    end

    # Every sensor, grouped, greens and all. The whole point of this view.
    def groups
      sensors.group_by { |sensor| sensor["group"].to_s }
             .sort_by { |group, _| GROUP_ORDER.index(group) || GROUP_ORDER.size }
             .flat_map { |group, members| [ group, *members.map { |sensor| row(sensor) }, "" ] }
             .tap(&:pop)
    end

    def row(sensor)
      "  #{icon_for(sensor)} #{sensor['id'].to_s.ljust(NAME_WIDTH)}#{detail(sensor)}"
    end

    # Stale outranks the verdict. A green that no longer describes the tree is
    # the one row on this board most likely to mislead someone.
    def icon_for(sensor)
      return ICONS.fetch("stale") if sensor["stale"]

      ICONS.fetch(sensor["state"].to_s, UNKNOWN_ICON)
    end

    # A red sensor's summary is what the reader needs; a green one's duration is
    # the only thing worth the space.
    def detail(sensor)
      return "#{sensor['summary']} (stale)" if sensor["stale"] && sensor["summary"]
      return "stale — the tree moved while it ran" if sensor["stale"]
      return sensor["summary"] if sensor["summary"]

      duration = sensor["duration_ms"]
      duration ? humanized(duration) : ""
    end

    def humanized(milliseconds)
      milliseconds < 1000 ? "#{milliseconds}ms" : "#{(milliseconds / 1000.0).round(1)}s"
    end

    def footer
      files = Array(status["changed_files"]).size
      load_ms = status.dig("config", "load_ms")
      # Shown past a threshold rather than always. It is the only lever keeping
      # the cheap-pass tenet honest across consumers core will never see, and a
      # config that boots Rails shows up here as the number it is.
      config = " · config #{load_ms}ms" if load_ms && load_ms > 100

      "#{files} file(s) changed vs #{status['base']} · #{status['mode']}#{config}"
    end
  end
end
