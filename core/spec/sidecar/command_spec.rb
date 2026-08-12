# frozen_string_literal: true

require_relative "../../lib/sidecar/command"

RSpec.describe Sidecar::Command do
  subject(:command) { described_class.new }

  describe "#call" do
    it "returns stdout, stderr and a status, matching capture3" do
      out, err, status = command.call("echo hello && echo oops >&2")

      expect(out.strip).to eq("hello")
      expect(err.strip).to eq("oops")
      expect(status).to be_success
    end

    it "reports a non-zero exit as a failure" do
      _out, _err, status = command.call("exit 7")

      expect(status).not_to be_success
      expect(status.exitstatus).to eq(7)
    end

    # One sensor the OS refuses to launch should be one red row, not the end of
    # the pass that was going to report on the other eleven. bin/mutant-ci
    # arrived without its executable bit and took down a whole slow run this way.
    it "reports a command it cannot start as a failed run rather than raising" do
      _out, err, status = command.call("/nonexistent/binary/entirely")

      expect(status).not_to be_success
      expect(err).not_to be_empty
    end

    # A sensor that fills the 64KB stderr pipe while nobody reads it would
    # deadlock. Brakeman gets close.
    it "drains both streams concurrently, so a chatty sensor cannot wedge the pass" do
      noisy = "ruby -e '200000.times { |i| $stderr.puts i }; puts :done'"

      out, err, status = command.call(noisy)

      expect(out.strip).to eq("done")
      expect(err.lines.size).to eq(200_000)
      expect(status).to be_success
    end
  end

  describe "#cancel!" do
    # Killing just the shell would orphan the process underneath it and leave it
    # competing for the machine — precisely what the sidecar exists not to do.
    # Spawning into its own group makes the whole tree killable in one signal.
    it "stops a running command" do
      thread = Thread.new { command.call("sleep 30") }
      sleep 0.2 until command.instance_variable_get(:@pgid)

      command.cancel!
      _out, _err, status = thread.value

      expect(status).not_to be_success
    end

    it "reports itself cancelled afterwards" do
      command.cancel!

      expect(command).to be_cancelled
    end

    # A pass being torn down must not start another sensor on its way out.
    it "makes a later command a no-op rather than starting it" do
      command.cancel!
      started = Time.now
      command.call("sleep 5")

      expect(Time.now - started).to be < 2
    end

    it "is safe to call when nothing is running" do
      expect { command.cancel! }.not_to raise_error
    end
  end

  # TERM asks politely. A sensor that ignores it, or is wedged in a syscall, still
  # has to go: the thread waiting on it would otherwise live for the rest of the
  # watcher's life, one leaked per cancelled pass.
  describe "#kill!" do
    it "stops a command that ignores TERM" do
      thread = Thread.new { command.call("trap '' TERM; sleep 30") }
      sleep 0.2 until command.instance_variable_get(:@pgid)

      command.cancel!
      command.kill!

      expect(thread.value.last).not_to be_success
    end

    it "is safe to call when nothing is running" do
      expect { command.kill! }.not_to raise_error
    end
  end
end
