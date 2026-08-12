# frozen_string_literal: true

require "json"
require "time"

require_relative "change_set"
require_relative "report"
require_relative "version"

module Sidecar
  # Answers the one question a separate process cannot answer for itself: can you
  # believe what it last wrote?
  #
  # A digest sitting in a file has no way to say it is out of date, so an agent
  # reading it directly can be told "all green" by a pass that ran before the bug
  # was written. This decides between three states and puts the verdict in an
  # exit code, so a dead or lagging sidecar cannot masquerade as a clean one.
  #
  #   :fresh  the pass describes the tree as it is now
  #   :stale  the tree moved since the pass — the results describe an older tree
  #   :down   there is no pass, or the watcher that promised to keep one stopped
  #
  # Freshness is judged against the working tree rather than the clock. A pass
  # from an hour ago on a tree nobody has touched is still accurate; a pass from
  # ten seconds ago is worthless if you saved a file since. The clock only
  # matters in watch mode, where a missing tick means the watcher itself died.
  class Liveness
    # Note these collide with the pass exit codes: `once` uses 1 for findings and
    # 2 for a failed run, where here 1 is stale and 2 is down. Documented rather
    # than renumbered, because renumbering spends a rename budget that was
    # deliberately kept at zero. A reader that needs to be sure should read
    # status.json's `schema` field instead of guessing from a number.
    EXIT_CODES = { fresh: 0, stale: 1, down: 2 }.freeze

    # In watch mode a tick is due every few seconds, so a minute of silence means
    # the loop is gone rather than merely idle.
    WATCH_HEARTBEAT_SECONDS = 60
    WATCH_MODE = "WATCH"

    def self.read(dir:, now: Time.now, change_set: nil)
      new(status: load_status(File.join(dir, Report::STATUS_FILE)), now:, change_set:)
    end

    def self.load_status(path)
      JSON.parse(File.read(path))
    rescue Errno::ENOENT, JSON::ParserError
      nil
    end

    def initialize(status:, now: Time.now, change_set: nil)
      @status = status
      @now = now
      @injected_change_set = change_set
    end

    def state = @state ||= compute_state

    def exit_code = EXIT_CODES.fetch(state)

    def fresh? = state == :fresh
    def down? = state == :down
    def ran? = !status.nil?

    def red_count = status&.dig("totals", "red").to_i
    def unavailable_count = status&.dig("totals", "unavailable").to_i

    def age_seconds = generated_at && (now - generated_at).round

    # The image carries its own bundle, so a host that bumped the gem runs a
    # different core against the same config until a rebuild. Reported as a
    # warning rather than refused: a stale image is one rebuild away, and
    # refusing would take the loop down over something advisory.
    def version_skew
      recorded = status&.dig("core", "version")
      return nil if recorded.nil? || recorded == Sidecar::VERSION

      "core #{recorded} wrote this, #{Sidecar::VERSION} is reading it — rebuild the runner image"
    end

    # The line `sidecar status` leads with.
    def headline
      case state
      when :fresh then "✓ SIDECAR FRESH — last pass #{humanized_age} ago · #{tier_summary}"
      when :stale then "⚠ SIDECAR STALE — #{drift_phrase} since the last pass #{humanized_age} ago. Do not trust green."
      else "⚠ SIDECAR DOWN — #{down_reason}. Do not trust green."
      end
    end

    def hint
      return nil if fresh?

      "  → run `sidecar once` to refresh"
    end

    # The single line the SessionStart hook emits. nil means stay quiet: if no
    # pass has ever run, the developer is not using the sidecar and nagging about
    # it every session would be noise.
    def nudge
      return nil unless ran?

      case state
      when :down then "Sidecar: down, #{down_reason} — run `sidecar once`"
      when :stale then "Sidecar: stale, #{drift_phrase} — run `sidecar once`"
      else fresh_nudge
      end
    end

    private

    attr_reader :status, :now

    def compute_state
      return :down if status.nil? || generated_at.nil?
      return :down if watcher_missed_its_beat?

      drifted_files.empty? ? :fresh : :stale
    end

    def fresh_nudge
      return "Sidecar: #{red_count} sensor(s) red — run `sidecar status`" if red_count.positive?

      # An unavailable tool is worth one word even on a green pass: the board is
      # green because a check never ran, which is not the same as passing.
      suffix = unavailable_count.positive? ? ", #{unavailable_count} tool(s) not installed" : ""
      "Sidecar: all green (last pass #{humanized_age} ago)#{suffix}"
    end

    def down_reason
      return "no pass has been run" unless ran? && generated_at

      "the watcher stopped #{humanized_age} ago"
    end

    def drift_phrase = "#{drifted_files.size} file(s) changed"

    def watcher_missed_its_beat?
      status["mode"] == WATCH_MODE && age_seconds > WATCH_HEARTBEAT_SECONDS
    end

    # What the tree has done since the pass: files that appeared or disappeared
    # from the change set, and files the pass looked at that have been written to
    # since.
    def drifted_files
      @drifted_files ||= begin
        recorded = Array(status["changed_files"])
        appeared_or_gone = (recorded | change_set.files) - (recorded & change_set.files)
        (appeared_or_gone + recorded.select { |file| edited_since_pass?(file) }).uniq
      end
    end

    def edited_since_pass?(file)
      File.mtime(file) > generated_at
    rescue SystemCallError
      true # gone since the pass, which is itself a change
    end

    def change_set
      @change_set ||= @injected_change_set ||
                      ChangeSet.from_git(base: status["base"] || ChangeSet::DEFAULT_BASE)
    end

    def generated_at
      return @generated_at if defined?(@generated_at)

      @generated_at = status && Time.parse(status["generated_at"].to_s)
    rescue ArgumentError, TypeError
      @generated_at = nil
    end

    # Reports the fast tier's state and says plainly that the slow tier has not
    # arrived yet, rather than leaving a silent gap that reads as green.
    def tier_summary
      fast = status.dig("tiers", "fast") ? "fast ✓current" : "fast — not run"
      "#{fast} · #{slow_summary}"
    end

    # A stale slow result is worth naming rather than folding into "current". It
    # is the one line that tells you a four-minute verdict is about code you have
    # already changed.
    def slow_summary
      slow = status.dig("tiers", "slow")
      return "slow — not run yet" unless slow

      slow["stale"] ? "slow ⚠stale" : "slow ✓current"
    end

    def humanized_age
      seconds = age_seconds.to_i
      return "#{seconds}s" if seconds < 60
      return "#{seconds / 60}m" if seconds < 3600
      return "#{seconds / 3600}h" if seconds < 86_400

      "#{seconds / 86_400}d"
    end
  end
end
