# frozen_string_literal: true

require_relative "../../lib/sidecar/stack"
require_relative "../../lib/sidecar/project"
require_relative "../../lib/sidecar/registry"

RSpec.describe Sidecar::Stack do
  # Captures the argv compose would have been given, and replays a canned result.
  let(:shell) do
    Class.new do
      attr_reader :calls
      attr_accessor :result

      def initialize
        @calls = []
        @result = Sidecar::Stack::Result.new(output: "", exit_code: 0)
      end

      def call(cmd, env, _quiet)
        @calls << { cmd:, env: }
        @result
      end
    end.new
  end

  def project(root: Dir.pwd, **rest)
    Sidecar::Project.new(root:, registry: Sidecar::Registry.new,
                         compose_file: "docker-compose.sidecar.yml", **rest)
  end

  def stack(cores: 16, memory_gb: 128, daemon_memory_gb: 64, **rest)
    described_class.new(shell:, cores:, memory_gb:, daemon_memory_gb:, **rest)
  end

  describe "#limits" do
    it "leaves the developer two cores" do
      expect(stack(cores: 16).limits["SIDECAR_CPUS"]).to eq("14")
    end

    it "never asks for fewer than one core on a small machine" do
      expect(stack(cores: 2).limits["SIDECAR_CPUS"]).to eq("1")
    end

    it "takes a quarter of the machine when the daemon has room to spare" do
      expect(stack(memory_gb: 128, daemon_memory_gb: 64).limits["SIDECAR_MEMORY"]).to eq("32g")
    end

    # On Docker Desktop the daemon's VM is far smaller than the Mac's RAM, so a
    # quarter of the host would exceed the whole VM and cap nothing at all.
    it "is bounded by the daemon's own allocation when that binds first" do
      expect(stack(memory_gb: 128, daemon_memory_gb: 8).limits["SIDECAR_MEMORY"]).to eq("6g")
    end

    it "exports the paths the shipped compose fragment reads" do
      limits = stack(project: project(root: "/srv/app", workdir: "/rails")).limits

      expect(limits).to include("SIDECAR_ROOT" => "/srv/app", "SIDECAR_WORKDIR" => "/rails",
                                "SIDECAR_LOCATION" => "container")
    end
  end

  describe "compose invocation" do
    # Base first so the isolation policy always loads, overlay second so a
    # project can extend but not replace it.
    it "loads the shipped base fragment before the project's overlay" do
      stack(project: project).compose("ps")

      files = shell.calls.last[:cmd].each_cons(2).select { |flag, _| flag == "-f" }.map(&:last)

      expect(files.first).to eq(Sidecar::Stack::BASE_COMPOSE)
      expect(files.last).to end_with("docker-compose.sidecar.yml")
    end

    it "resolves the base fragment to a file that actually ships" do
      expect(File.file?(Sidecar::Stack::BASE_COMPOSE)).to be(true)
    end

    # Every pass runs behind nice and ionice: the caps decide how much the
    # sidecar may take, this decides who yields when the host is busy. An exec
    # starts fresh and inherits neither, so it goes on the exec.
    it "runs an exec at low priority" do
      stack(project: project).exec("bundle", "exec", "sidecar", "once")

      expect(shell.calls.last[:cmd]).to include("nice", "-n", "19", "ionice", "-c", "3")
    end
  end

  describe "#running?" do
    it "is true when the runner service is up" do
      shell.result = Sidecar::Stack::Result.new(output: "runner\n", exit_code: 0)

      expect(stack(project: project)).to be_running
    end

    # No docker, no daemon, stack down — all false rather than an exception, so
    # the caller can fall back to a host-side pass instead of failing.
    it "is false when compose cannot answer" do
      shell.result = Sidecar::Stack::Result.new(output: "", exit_code: 127)

      expect(stack(project: project)).not_to be_running
    end
  end

  describe "#start" do
    it "brings the stack up with the caps as environment" do
      stack(project: project).start

      expect(shell.calls.last[:cmd]).to include("up", "-d", "--wait")
      expect(shell.calls.last[:env]).to include("SIDECAR_CPUS")
    end

    # The failure this prevents is silent and total: the container mounts the
    # gem instead of the project, watches the wrong tree, and reports green
    # forever.
    it "refuses when the mount source would not be the project root" do
      expect { stack(project: project(root: "/nowhere/that/exists")).start }
        .to raise_error(described_class::MountMismatch)
    end
  end
end
