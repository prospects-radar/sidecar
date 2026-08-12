# frozen_string_literal: true

require_relative "change_set"
require_relative "command"
require_relative "scan"

module Sidecar
  # The expensive sensors — full suites, mutation testing, subdirectory suites —
  # and the rules for running them without thrashing.
  #
  # Everything here is the opposite of the fast tier, on purpose:
  #
  #   fast                           slow
  #   every couple of seconds        only when the tree has gone quiet
  #   cancelled the moment you type  never cancelled once started
  #   always describes now           may finish describing a tree that has moved
  #
  # The last row is the interesting one. A mutation run takes minutes, and the
  # developer will not sit still for it. Rather than cancel (throwing away
  # minutes of work every time someone saves a file) or pretend (reporting a
  # verdict about code that no longer exists), a run whose covered files moved
  # underneath finishes and is marked stale.
  class SlowTier
    # How long the tree has to sit still before the expensive work is allowed to
    # start. Long enough that it will not fire between two keystrokes, short
    # enough to catch a coffee break.
    IDLE_AFTER = 60.0

    # `sample` re-reads the tree. Staleness is a question about now, not about
    # the change set this run started from, so it cannot be answered from the
    # snapshot the run was handed.
    def initialize(sensors:, project:, location: :host, scanner: nil, sample: nil)
      @sensors = sensors.select { |sensor| sensor.tier == :slow }
      @project = project
      @location = location
      @scanner = scanner || method(:default_scan)
      @sample = sample || -> { ChangeSet.from_git(base: project.base) }
      @covered = {}
    end

    # Opportunistic, and every clause earns its place: expensive work should not
    # start while the cheap checks are still failing (the failure is the thing to
    # fix), nor while the developer is mid-flow, nor on top of a run already
    # going, nor when there is nothing to run.
    #
    # That last clause is not an optimisation. Without it an idle tree is
    # permanently due: the watcher starts a run, #pending hands it nothing, the
    # empty run finishes instantly, and the next tick starts another. Both ticks
    # return before the heartbeat, so the loop spins without ever refreshing the
    # digest and Liveness reports a perfectly healthy sidecar as DOWN sixty
    # seconds later.
    #
    # Checked last because it is the only clause that stats the tree.
    def due?(fast_results:, idle_for:, change_set:, running: false)
      return false if running
      return false if idle_for < IDLE_AFTER
      return false if fast_results.nil? || fast_results.any?(&:actionable?)

      pending(change_set).any?
    end

    # Only what has moved since that sensor last ran. Re-running a full suite
    # over a subsystem nobody touched is the thrash this tier exists to avoid.
    def pending(change_set)
      @sensors.select { |sensor| changed_since_last_run?(sensor, change_set) }
    end

    # Runs to completion. There is no cancellation path by design — see the class
    # comment. Returns results, each flagged stale if the files it covered moved
    # while it was running.
    def run(change_set, sensors: pending(change_set))
      return [] if sensors.empty?

      before = sensors.to_h { |sensor| [ sensor.id, coverage(sensor, change_set) ] }
      results = @scanner.call(change_set, sensors)
      after_tree = @sample.call

      results.map { |result| mark_staleness(result, before, after_tree) }
    end

    private

    attr_reader :project, :location

    def changed_since_last_run?(sensor, change_set)
      current = coverage(sensor, change_set)
      # Nothing in this sensor's scope has been touched at all. Without this a
      # sensor that matches no files reads as "never run" forever, because
      # never-run (nil) and matched-nothing ([]) compare unequal — so it would
      # sit in the pending list for good, offering work there is none of.
      return false if current.empty? && sensor.scope.any?

      @covered[sensor.id] != current
    end

    # What this sensor's scope currently matches, and when each of those was last
    # written. Two runs agree only if both the file list and the contents'
    # timestamps agree.
    def coverage(sensor, change_set)
      change_set.matching(sensor.scope).map { |file| [ file, mtime(file) ] }
    end

    def mtime(file)
      File.mtime(file).to_f
    rescue SystemCallError
      nil
    end

    def mark_staleness(result, before, after_tree)
      sensor = @sensors.find { |candidate| candidate.id == result.id }
      return result unless sensor

      after = coverage(sensor, after_tree)
      # Recorded either way: a stale run still tells the next pass that this
      # scope has been covered, so it does not immediately run again.
      @covered[sensor.id] = after

      result.with(stale: before[sensor.id] != after)
    end

    def default_scan(change_set, sensors)
      Scan.new(change_set:, sensors:, project:, location:, tier: :slow, runner: Command.new).run
    end
  end
end
