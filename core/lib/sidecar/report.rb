# frozen_string_literal: true

require "fileutils"
require "json"
require "time"

require_relative "digest"
require_relative "version"

module Sidecar
  # Writes the two artifacts a pass produces.
  #
  #   status.json       every sensor, every violation including pre-existing.
  #                     The structured source the board and the liveness check
  #                     both read, and the published integration contract: the
  #                     process that wrote it is routinely not one an integrator
  #                     can call into, since a pass execs into the container.
  #   agent-summary.md  the rendered, budget-capped digest an agent reads.
  #
  # Both are written temp-then-rename. A reader arriving mid-write gets the
  # previous pass in full rather than half of this one, which matters because the
  # watch loop rewrites these every few seconds while an agent may be reading.
  class Report
    STATUS_FILE = "status.json"
    DIGEST_FILE = "agent-summary.md"

    def self.write(...) = new(...).write

    def initialize(results:, change_set:, dir:, project: nil, generated_at: Time.now,
                   mode: "ONCE", location: :host)
      @results = results
      @change_set = change_set
      @dir = dir
      @project = project
      @generated_at = generated_at
      @mode = mode
      @location = location
    end

    # Returns the digest text so the caller can print exactly what it wrote.
    def write
      FileUtils.mkdir_p(dir)
      digest = Digest.new(results:, change_set:, generated_at:, mode:).to_s
      write_atomic(STATUS_FILE, "#{JSON.pretty_generate(status)}\n")
      write_atomic(DIGEST_FILE, digest)
      digest
    end

    def status
      {
        schema: STATUS_SCHEMA,
        generated_at: generated_at.iso8601,
        mode:,
        base: change_set.base,
        # Recorded per location, so a host that bumped the gem and a container
        # still on its old bundle show up as the two versions they are. Reported
        # as a warning rather than refused: a stale image is one rebuild away.
        core: { version: Sidecar::VERSION, location: location.to_s },
        config: { load_ms: project&.load_ms },
        changed_files: change_set.files,
        tiers:,
        totals:,
        sensors: results.map(&:to_h)
      }
    end

    private

    attr_reader :results, :change_set, :dir, :project, :generated_at, :mode, :location

    # The slow tier only appears once it has actually produced something, so a
    # reader can tell "not run yet" from "run and current" — and, when a run
    # finished about a tree that had already moved, from "run but stale".
    def tiers
      fast = { ran_at: generated_at.iso8601, duration_ms: total_duration_ms }
      slow = results.select { |result| result.tier == :slow }
      return { fast: } if slow.empty?

      { fast:, slow: { ran_at: generated_at.iso8601, sensors: slow.size, stale: slow.any?(&:stale?) } }
    end

    def totals
      {
        red: results.count(&:actionable?),
        green: results.count(&:green?),
        deferred: results.count(&:deferred?),
        # Its own count rather than folded into deferred. A resource this
        # location lacks and a tool nobody installed are different problems with
        # different fixes, and one board line each is what makes that visible.
        unavailable: results.count(&:unavailable?),
        new_violations: results.sum { |result| result.new_violations.size },
        preexisting: results.sum { |result| result.preexisting.size }
      }
    end

    def total_duration_ms = results.filter_map(&:duration_ms).sum

    def write_atomic(name, content)
      final = File.join(dir, name)
      temp = File.join(dir, ".#{name}.tmp")
      File.write(temp, content)
      File.rename(temp, final)
      final
    end
  end
end
