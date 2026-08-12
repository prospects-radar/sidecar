# frozen_string_literal: true

require "open3"

module Sidecar
  # Runs a sensor's shell command, and can be told to stop.
  #
  # Cancellation kills the whole process group rather than the shell alone. A
  # sensor is `sh -c "bundle exec rubocop …"`, so killing just the shell would
  # orphan the bundle underneath it and leave it competing for the machine —
  # precisely what the sidecar exists not to do. Spawning into its own group
  # makes the whole tree killable in one signal.
  class Command
    # A cancelled command has no meaningful exit status, so it reports one that
    # cannot be mistaken for a real sensor verdict.
    CANCELLED_STATUS = 130

    # The shell's own code for "found it, could not run it".
    UNLAUNCHABLE_STATUS = 126

    Status = Data.define(:exitstatus) do
      def success? = exitstatus.zero?
    end

    def initialize
      @mutex = Mutex.new
      @pgid = nil
      @cancelled = false
    end

    def cancelled? = @mutex.synchronize { @cancelled }

    # Returns [stdout, stderr, status], matching what Open3.capture3 gives, so
    # this drops in wherever the plain runner was used.
    #
    # A command that cannot start at all — missing binary, lost its executable
    # bit — comes back as a failed run rather than an exception. One sensor the
    # OS refuses to launch should be one red row, not the end of the pass that
    # was going to report on the other eleven. `bin/mutant-ci` arrived without
    # its executable bit and took down a whole slow run this way.
    def call(command)
      spawn(command)
    rescue SystemCallError => e
      [ "", "could not start: #{e.message}", Status.new(exitstatus: UNLAUNCHABLE_STATUS) ]
    end

    def spawn(command)
      Open3.popen3(command, pgroup: true) do |stdin, stdout, stderr, wait_thread|
        stdin.close
        track(wait_thread.pid)

        # Drained concurrently: a sensor that fills the 64KB stderr pipe while
        # nobody is reading it would deadlock. Brakeman gets close.
        out = Thread.new { stdout.read }
        err = Thread.new { stderr.read }

        [ out.value, err.value, Status.new(exitstatus: wait_thread.value.exitstatus || CANCELLED_STATUS) ]
      end
    ensure
      track(nil)
    end

    # Stops whatever is running now and makes every later call a no-op, so a
    # pass being torn down cannot start another sensor on its way out.
    def cancel!
      @mutex.synchronize do
        @cancelled = true
        signal_group(@pgid, "TERM")
      end
    end

    # TERM asks politely. A sensor that ignores it, or is wedged in a syscall,
    # still has to go: the thread waiting on it would otherwise live for the
    # rest of the watcher's life, one leaked per cancelled pass.
    def kill!
      @mutex.synchronize { signal_group(@pgid, "KILL") }
    end

    private

    def track(pid)
      @mutex.synchronize do
        @pgid = pid
        # Lost the race: cancel! arrived while this command was starting, so
        # nothing was running for it to kill. Stop this one immediately.
        signal_group(pid, "TERM") if pid && @cancelled
      end
    end

    # Negative pid = the whole group. Already-dead groups raise, which is a
    # normal outcome of racing a process that just exited.
    def signal_group(pgid, signal)
      return unless pgid

      Process.kill("-#{signal}", pgid)
    rescue Errno::ESRCH, Errno::EPERM
      nil
    end
  end
end
