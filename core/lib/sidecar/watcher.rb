# frozen_string_literal: true

require_relative "change_set"
require_relative "command"
require_relative "report"
require_relative "scan"
require_relative "slow_tier"

module Sidecar
  # The always-on part: watch the tree, and keep the digest describing it.
  #
  # Polls rather than subscribes. fsevents and inotify do not survive a
  # host-to-container bind mount, so a watcher built on them would sit silent
  # while the developer typed. A poll every couple of seconds is
  # dependency-free and cannot be fooled by the mount.
  #
  # What it polls is the change set, not the file system directly. A `touch` that
  # alters no content changes no sensor's verdict, and git already knows the
  # difference — so the fingerprint is built from which files differ from the
  # base and when they were last written.
  class Watcher
    POLL_INTERVAL = 2.0

    # Long enough that a save-everything keystroke lands as one run, short enough
    # that a single save still feels immediate.
    DEBOUNCE = 0.75

    # An idle watcher must keep saying so. Liveness reads a WATCH-mode pass older
    # than a minute as a dead loop, so a quiet tree still gets its timestamp
    # refreshed well inside that window.
    HEARTBEAT_INTERVAL = 30.0

    # How long a cancelled pass is given to unwind before the next one starts.
    CANCEL_GRACE = 10.0

    MODE = "WATCH"

    def initialize(project:, location: :host, dir: nil,
                   sample: nil, scanner: nil, writer: nil, migrator: nil, seeder: nil, slow: nil,
                   clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) },
                   sleeper: ->(seconds) { sleep(seconds) })
      @project = project
      @location = location
      @dir = dir || project.artifacts_path
      @sample = sample || -> { ChangeSet.from_git(base: project.base) }
      @scanner = scanner || method(:default_scan)
      @writer = writer || method(:default_write)
      @migrator = migrator || method(:default_migrate)
      @seeder = seeder || method(:default_seed)
      @slow = slow || SlowTier.new(sensors: project.registry.slow, project:, location:,
                                   sample: -> { @sample.call })
      @clock = clock
      @sleeper = sleeper
      @last_seen = nil
      @last_written_at = nil
      @last_results = nil
      @last_change_set = nil
      @rebuilt_for = nil
      @slow_results = []
      @slow_worker = nil
      @slow_change_set = nil
      @tree_settled_at = nil
      @last_shape = nil
      @last_fast_results = nil
    end

    # Cold start is a full sweep: on a tree with no uncommitted work the
    # incremental path would report nothing at all, and an empty digest is
    # indistinguishable from a clean one. Then it settles into polling.
    def run(cycles: nil)
      prepare_data_plane
      attempt { baseline }
      completed = 0

      while cycles.nil? || completed < cycles
        attempt { tick }
        completed += 1
        @sleeper.call(POLL_INTERVAL)
      end
    end

    # A loop that dies on one bad pass is not an always-on loop, and the baseline
    # sweep can fail the same way a later one can. Nothing is hidden by
    # surviving: a watcher that keeps failing writes nothing, so the digest stops
    # advancing and Liveness reports it stale and then down. Carrying on costs no
    # honesty and buys the availability the tier exists for.
    def attempt
      yield
    rescue StandardError => e
      warn "sidecar: pass failed — #{e.class}: #{e.message}"
      :failed
    end

    # A cold data plane would make the first pass report every test sensor as
    # failing against a database that does not exist yet.
    #
    # Guarded on not being the host, and that guard is load-bearing: the only
    # database on a developer's machine belongs to the developer, and preparing
    # or seeding it would drop their data.
    def prepare_data_plane
      return if location == :host
      return unless project.prepare_command

      @migrator.call
      @seeder.call if project.seed_command
    end

    def baseline
      change_set = @sample.call
      perform(change_set, fingerprint(change_set))
    end

    # One iteration. Returns what it did — which is what the specs assert on, and
    # what makes the loop above trivial.
    def tick
      change_set = @sample.call
      current = fingerprint(change_set)

      note_settled(current)
      # Collected first and unconditionally: a slow run that finished should be
      # published whether or not the tree has moved since.
      collected = collect_slow

      return fast_pass(current) unless current == @last_seen
      return :slow if collected || start_slow_if_due(change_set)

      heartbeat_or_idle
    end

    # Run the expensive tier now, whatever the clock says. This is the on-demand
    # half; the opportunistic half is decided in #start_slow_if_due.
    def run_slow_now
      collect_slow
      change_set = @sample.call
      results = @slow.run(change_set)
      absorb_slow(results, change_set)
      results
    end

    private

    attr_reader :dir, :project, :location

    # Waits out the burst. A save-all writes a dozen files over a few hundred
    # milliseconds, and each one would otherwise start its own pass.
    def settle(seen)
      @sleeper.call(DEBOUNCE)
      after = fingerprint(@sample.call)

      # Still moving. Leave it for the next tick rather than chasing it.
      after == seen ? after : nil
    end

    # The tree has stopped moving as of now if this is the first tick that saw it
    # in its current shape.
    def note_settled(current)
      return if current == @last_shape

      @last_shape = current
      @tree_settled_at = @clock.call
    end

    def idle_for = @tree_settled_at ? @clock.call - @tree_settled_at : 0

    def heartbeat_or_idle = heartbeat_due? ? heartbeat : :idle

    def fast_pass(current)
      settled = settle(current)
      return :settling unless settled

      perform(@sample.call, settled)
    end

    # The tier decides whether it is due, including whether it has anything to
    # run — so it is handed this tick's tree rather than reading its own.
    def start_slow_if_due(change_set)
      return false if @slow_worker
      return false unless @slow.due?(fast_results: @last_fast_results, idle_for:, change_set:)

      start_slow(change_set)
      true
    end

    # Never joined with a deadline and never cancelled — that is the tier's
    # defining promise. The watcher keeps polling and keeps running fast passes
    # while this thread works.
    def start_slow(change_set)
      @slow_change_set = change_set
      @slow_worker = Thread.new { @slow.run(change_set) }
      @slow_worker.report_on_exception = false
    end

    def collect_slow
      return false unless @slow_worker
      return false if @slow_worker.alive?

      results = @slow_worker.value
      @slow_worker = nil
      absorb_slow(results, @slow_change_set)
      true
    rescue StandardError => e
      @slow_worker = nil
      warn "sidecar: slow tier failed — #{e.class}: #{e.message}"
      false
    end

    # Slow results live alongside the fast ones in the same report, replacing
    # whatever that sensor last said.
    def absorb_slow(results, change_set)
      return false if results.empty?

      replaced = results.map(&:id)
      @slow_results = @slow_results.reject { |result| replaced.include?(result.id) } + results
      write(@last_results || [], change_set || @last_change_set)
      true
    end

    def perform(change_set, expected)
      rebuild_data_plane_if_needed(change_set)

      command = Command.new
      worker = Thread.new { @scanner.call(change_set, command) }
      # The failure is re-raised through worker.value and reported by #attempt;
      # Ruby's own thread-death dump would just print it a second time.
      worker.report_on_exception = false
      results = supervise(worker, command, expected)

      return :cancelled unless results

      @last_fast_results = results
      write(results, change_set)
      @last_seen = expected
      :ran
    end

    # Watches the tree while the pass runs. An edit landing mid-pass makes every
    # result that follows describe a tree that no longer exists, so the pass is
    # killed and the next tick starts a fresh one.
    def supervise(worker, command, expected)
      until worker.join(POLL_INTERVAL)
        next if fingerprint(@sample.call) == expected

        command.cancel!
        # Escalate rather than wait forever. A sensor that shrugs off TERM would
        # otherwise strand this thread for the life of the watcher.
        force_stop(command, worker) unless worker.join(CANCEL_GRACE)
        return nil
      end

      command.cancelled? ? nil : worker.value
    end

    def force_stop(command, worker)
      command.kill!
      worker.join(CANCEL_GRACE)
    end

    def heartbeat_due?
      @last_written_at.nil? || (@clock.call - @last_written_at) >= HEARTBEAT_INTERVAL
    end

    # Rewrites the same findings with a current timestamp. Nothing has changed,
    # and that is the message: the loop is alive and the answer still holds.
    def heartbeat
      return :idle unless @last_results

      write(@last_results, @last_change_set)
      :heartbeat
    end

    def write(results, change_set)
      @writer.call(results + @slow_results, change_set)
      @last_results = results
      @last_change_set = change_set
      @last_written_at = @clock.call
    end

    # Which files mean the data plane is out of date is the project's call, not a
    # regex in here. The container also cannot run a migration that writes a new
    # schema file: the mount is read-only, so the project's prepare command is
    # expected to reload from schema rather than generate one.
    def rebuild_data_plane_if_needed(change_set)
      return unless project.prepare_command
      return unless project.rebuilds_data_plane?(change_set.files)

      stamp = change_set.files.map { |file| [ file, mtime(file) ] }
      return if stamp == @rebuilt_for

      @migrator.call
      @rebuilt_for = stamp
    end

    def fingerprint(change_set)
      change_set.files.map { |file| [ file, mtime(file) ] }
    end

    def mtime(file)
      File.mtime(file).to_f
    rescue SystemCallError
      nil
    end

    def default_scan(change_set, command)
      Scan.new(change_set:, sensors: project.registry.fast, project:, location:,
               tier: :fast, runner: command, cancelled: -> { command.cancelled? }).run
    end

    def default_write(results, change_set)
      Report.write(results:, change_set:, dir:, project:, location:, mode: MODE)
    end

    def default_migrate = Command.new.call(project.prepare_command)
    def default_seed = Command.new.call(project.seed_command)
  end
end
