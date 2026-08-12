# frozen_string_literal: true

require "English"
require "etc"
require "open3"
require "rbconfig"

module Sidecar
  # The container stack: bringing it up, taking it down, and asking whether a
  # pass should run inside it.
  #
  # The compose files hold the isolation policy. This holds the two decisions
  # that need the host to make them — how large the caps should be on *this*
  # machine, and whether the stack is actually up right now.
  class Stack
    # The base fragment ships inside the gem so the isolation policy improves
    # with a bundle bump rather than being copied once into a project and
    # frozen. Resolved __dir__-relative and NOT through Gem.loaded_specs, which
    # returns nil for a gem loaded outside bundler's gem resolution — exactly the
    # `path:` case used every day in development, where the failure would be a
    # nil path reaching `docker compose -f`.
    BASE_COMPOSE = File.expand_path("../../compose/base.yml", __dir__)

    Result = Data.define(:output, :exit_code) do
      def success? = exit_code.zero?
    end

    MountMismatch = Class.new(StandardError)

    # Leave the developer two cores. The container exists so the machine stays
    # usable while it works; a cap that swallowed every core would break the
    # tenet in the one place built to enforce it.
    RESERVED_CORES = 2
    MIN_CORES = 1

    # A quarter of the machine — enough for a test process, not enough to push
    # the app the developer is running into swap.
    MEMORY_FRACTION = 4
    MIN_MEMORY_GB = 2

    # Of whatever the docker daemon itself has, leave a quarter for the database
    # and the daemon's own overhead.
    DAEMON_HEADROOM = 4

    def initialize(project: nil, shell: nil, cores: Etc.nprocessors,
                   memory_gb: Stack.host_memory_gb, daemon_memory_gb: nil)
      @project = project
      @shell = shell || method(:run_command)
      @cores = cores
      @memory_gb = memory_gb
      @daemon_memory_gb = daemon_memory_gb
    end

    def self.host_memory_gb
      if RbConfig::CONFIG["host_os"].match?(/darwin/)
        Integer(`sysctl -n hw.memsize`) / (1024**3)
      else
        File.read("/proc/meminfo")[/MemTotal:\s+(\d+)/, 1].to_i / (1024**2)
      end
    rescue StandardError
      0
    end

    # Caps sized for this machine, plus the paths the base fragment reads.
    #
    # A fixed, core-owned list. A project needing more uses its own overlay or
    # compose's `.env`, rather than this growing an escape hatch that would make
    # the base fragment's inputs unknowable.
    def limits
      usable = [ cores - RESERVED_CORES, MIN_CORES ].max

      {
        "SIDECAR_CPUS" => usable.to_s,
        "SIDECAR_MEMORY" => "#{memory_limit_gb}g",
        "SIDECAR_ROOT" => project&.root.to_s,
        "SIDECAR_WORKDIR" => project&.workdir.to_s,
        "SIDECAR_ARTIFACTS" => project&.artifacts.to_s,
        "SIDECAR_LOCATION" => "container"
      }
    end

    # Whichever ceiling binds first.
    #
    # On Linux the container shares host memory directly, so a quarter of the
    # machine is the limit that matters. On Docker Desktop the daemon runs in a
    # VM with its own fixed allocation, usually far smaller than the Mac's RAM —
    # a quarter of the host would exceed the whole VM and cap nothing at all.
    # Taking the smaller of the two makes the number mean something on both.
    def memory_limit_gb
      candidates = [ memory_gb / MEMORY_FRACTION,
                     daemon_memory_gb - (daemon_memory_gb / DAEMON_HEADROOM) ].reject(&:zero?)

      [ candidates.min || MIN_MEMORY_GB, MIN_MEMORY_GB ].max
    end

    # What the docker daemon reports for itself, which on Docker Desktop is the
    # VM rather than the Mac.
    def daemon_memory_gb
      @daemon_memory_gb ||= begin
        result = @shell.call([ "docker", "info", "--format", "{{.MemTotal}}" ], {}, true)
        result.success? ? result.output.strip.to_i / (1024**3) : 0
      end
    end

    def start
      verify_mount!
      compose("up", "-d", "--wait", env: limits)
    end

    def stop = compose("down")

    # True when the runner is up and can take an exec. Every other answer — no
    # docker, no daemon, stack down — is false rather than an exception, so a
    # caller can fall back to a host-side pass instead of failing.
    def running?
      result = compose("ps", "--status", "running", "--format", "{{.Service}}", quiet: true)
      result.success? && result.output.split("\n").include?(runner)
    end

    # Every pass runs behind nice and ionice. The cgroup caps decide how much the
    # sidecar may take; this decides who yields when the host is busy, and it
    # belongs here rather than on the container's idle process because an exec
    # starts fresh and inherits neither.
    LOW_PRIORITY = %w[nice -n 19 ionice -c 3].freeze

    def exec(*command, quiet: false)
      compose("exec", "-T", runner, *LOW_PRIORITY, *command, quiet:)
    end

    def compose(*args, env: {}, quiet: false)
      @shell.call([ "docker", "compose", *compose_files, *args ], env, quiet)
    end

    private

    attr_reader :cores, :memory_gb, :project

    def runner = project&.runner_service || "runner"

    # Base first, then the project's overlay, so the project can extend the
    # isolation policy but the policy itself always loads.
    def compose_files
      files = [ "-f", BASE_COMPOSE ]
      overlay = project&.compose_file
      files += [ "-f", File.expand_path(overlay, project.root) ] if overlay
      files
    end

    # The base fragment now lives at an absolute path inside the installed gem,
    # so a relative source in its volume line would resolve against whatever
    # directory compose picked rather than against the project. If that ever
    # differed, the sidecar would mount the gem instead of the project and say
    # nothing — a container watching the wrong tree, reporting green forever.
    #
    # Refusing here is the second clause beside the read-only one.
    def verify_mount!
      return if project.nil?

      root = File.realpath(project.root)
      declared = limits["SIDECAR_ROOT"]
      return if declared == project.root.to_s && File.realpath(declared) == root

      raise MountMismatch,
            "the runner would mount #{declared.inspect}, which is not the project root #{root.inspect}"
    rescue Errno::ENOENT => e
      raise MountMismatch, "cannot resolve the project root to mount: #{e.message}"
    end

    # Streams to the terminal unless asked not to: `start` may build an image,
    # and a silent multi-minute wait reads as a hang. A missing docker binary is
    # an ordinary answer here ("no stack"), not an exception worth raising.
    def run_command(cmd, env, quiet)
      if quiet
        out, _err, status = Open3.capture3(env, *cmd)
        Result.new(output: out, exit_code: status.exitstatus || 1)
      else
        system(env, *cmd)
        Result.new(output: "", exit_code: $CHILD_STATUS&.exitstatus || 1)
      end
    rescue Errno::ENOENT
      Result.new(output: "", exit_code: 127)
    end
  end
end
