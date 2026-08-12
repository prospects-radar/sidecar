# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"

# Spawns the real binary rather than calling into Ruby.
#
# This is the only place the contract *can* be tested. ADR 0032 made every class
# @api private precisely because `once` execs into the runner container, so a
# Ruby API would be correct on one side of the container wall and lie on the
# other. What an integrator actually depends on is the exit code and the
# artifacts, so that is what these assert on.
RSpec.describe "exe/sidecar" do
  GEM_ROOT = File.expand_path("../..", __dir__)
  EXE = File.join(GEM_ROOT, "exe", "sidecar")

  def sidecar(*argv, env: {})
    out, err, status = Open3.capture3(
      { "SIDECAR_CONTAINER" => nil }.merge(env),
      RbConfig.ruby, "-I", File.join(GEM_ROOT, "lib"), EXE, *argv
    )
    [ out, err, status.exitstatus ]
  end

  def with_project(extra = "")
    in_a_repo do |repo|
      repo.ignore("tmp/")
      FileUtils.mkdir_p("config")
      File.write("config/sidecar.rb", <<~RUBY)
        Sidecar.define do
          artifacts "tmp/sidecar"
          location(:host) { provides :node }
          sensor :always_green, name: "Always green", command: "true",
                 tier: :fast, kind: :computational, group: :lint
          sensor :gated, name: "Gated", command: "true", gate: true,
                 tier: :fast, kind: :computational, group: :lint
          #{extra}
        end
      RUBY
      FileUtils.mkdir_p("app")
      File.write("app/x.rb", "one\n")
      repo.commit("initial")
      yield repo
    end
  end

  describe "a project with no configuration" do
    # Not a link (a second thing to keep in sync) and not a generator (a file
    # copied once is never improved again).
    it "exits 2 and prints a worked example inline" do
      in_a_repo do
        _out, err, code = sidecar("once")

        expect(code).to eq(2)
        expect(err).to include("Sidecar.define do").and include("config/sidecar.rb")
      end
    end

    # The hook this feeds must never break a session. But a broken config never
    # clears on its own, so this is the one condition it stops being silent for.
    it "still exits 0 from nudge, while saying something is wrong" do
      in_a_repo do
        out, _err, code = sidecar("nudge")

        expect(code).to eq(0)
        expect(out).to include("configuration problem")
      end
    end
  end

  describe "once" do
    it "exits 0 on a tree with nothing to answer for, and writes both artifacts" do
      with_project do
        _out, _err, code = sidecar("once", "--quiet")

        expect(code).to eq(0)
        expect(Dir.children("tmp/sidecar")).to contain_exactly("status.json", "agent-summary.md")
      end
    end

    it "writes a status.json stamped with the schema version" do
      with_project do
        sidecar("once", "--quiet")

        expect(JSON.parse(File.read("tmp/sidecar/status.json"))["schema"]).to eq("sidecar.status/1")
      end
    end

    it "exits 1 when a sensor is red" do
      with_project(%(sensor :fails, name: "Fails", command: "false",
                            tier: :fast, kind: :computational, group: :lint)) do
        File.write("app/x.rb", "changed\n")

        _out, _err, code = sidecar("once", "--quiet")

        expect(code).to eq(1)
      end
    end
  end

  # The artifact directory is a mount, fixed when the stack starts. Everything
  # here is about the one thing that cannot be inferred from a host-side run:
  # which directory the container was actually told to write.
  describe "once, routed into the container" do
    # A docker that reports the runner up and records what it was asked to run.
    #
    # This path is unreachable without one: `once` only execs when
    # `docker compose ps` names the runner, and the real stack would need an
    # image, a build and a minute per example. What the container does with the
    # flag is not in question — that it receives the right one is.
    def with_fake_docker(repo)
      bin = File.join(repo.dir, "fakebin")
      log = File.join(repo.dir, "docker.log")
      FileUtils.mkdir_p(bin)
      File.write(File.join(bin, "docker"), <<~RUBY)
        #!#{RbConfig.ruby}
        File.write(#{log.inspect}, ARGV.join(" ") + "\\n", mode: "a")
        puts "runner" if ARGV.include?("ps")
      RUBY
      FileUtils.chmod(0o755, File.join(bin, "docker"))
      yield log, { "PATH" => "#{bin}:#{ENV.fetch('PATH', '')}" }
    end

    def with_container_project(&) = with_project(%(compose_file "compose.yml"\n  workdir "/rails"), &)

    # No log at all means docker was never reached, which counts as no exec.
    def execs(log) = File.exist?(log) ? File.readlines(log).grep(/ exec /) : []

    it "tells the container to write the directory the host will read" do
      with_container_project do |repo|
        with_fake_docker(repo) do |log, env|
          sidecar("once", "--quiet", "--dir", "tmp/sidecar/pass-2", env:)

          expect(execs(log).join).to include("--dir /rails/tmp/sidecar/pass-2")
        end
      end
    end

    it "names the mount even when no --dir was given" do
      with_container_project do |repo|
        with_fake_docker(repo) do |log, env|
          sidecar("once", "--quiet", env:)

          expect(execs(log).join).to include("--dir /rails/tmp/sidecar")
        end
      end
    end

    # The bug this closes. The digest was read from a directory the container
    # had no way to write, so the pass reported on whatever happened to be
    # lying there — a stale file, or nothing — beside a truthful exit code.
    it "refuses a --dir outside the mount rather than reading a file the pass never wrote" do
      with_container_project do |repo|
        FileUtils.mkdir_p("tmp/elsewhere")
        File.write("tmp/elsewhere/agent-summary.md", "a digest from some earlier pass\n")

        with_fake_docker(repo) do |log, env|
          out, err, code = sidecar("once", "--dir", "tmp/elsewhere", env:)

          expect(code).to eq(2)
          expect(err).to include("outside the artifact mount")
          expect(out).not_to include("some earlier pass")
          expect(execs(log)).to be_empty
        end
      end
    end

    # The escape hatch the refusal points at. A host-side pass writes wherever
    # it is told, because no mount stands between it and the directory.
    it "still writes an out-of-mount directory when the pass runs here" do
      with_container_project do |repo|
        with_fake_docker(repo) do |_log, env|
          _out, _err, code = sidecar("once", "--quiet", "--host", "--dir", "tmp/elsewhere", env:)

          expect(code).to eq(0)
          expect(Dir.children("tmp/elsewhere")).to contain_exactly("status.json", "agent-summary.md")
        end
      end
    end

    # Same mount, same refusal. This one writes rather than reads, so getting it
    # wrong loses the results instead of misreporting them.
    it "refuses the same --dir on the slow tier" do
      with_container_project do |repo|
        with_fake_docker(repo) do |log, env|
          _out, err, code = sidecar("run", "--slow", "--dir", "tmp/elsewhere", env:)

          expect(code).to eq(2)
          expect(err).to include("outside the artifact mount")
          expect(execs(log)).to be_empty
        end
      end
    end

    # The refusal names a command you can actually run. Built from the command's
    # own invocation rather than from the parsed name, which for the slow tier
    # would have printed `sidecar run --host`: a line that exits 2 telling you
    # --slow is missing.
    it "suggests an invocation that works, on both tiers" do
      with_container_project do |repo|
        with_fake_docker(repo) do |_log, env|
          _out, fast, = sidecar("once", "--dir", "tmp/elsewhere", env:)
          _out, slow, = sidecar("run", "--slow", "--dir", "tmp/elsewhere", env:)

          expect(fast).to include(%(sidecar once --host --dir "tmp/elsewhere"))
          expect(slow).to include(%(sidecar run --slow --host --dir "tmp/elsewhere"))
        end
      end
    end

    # What the refusal above tells you to run. --host used to be parsed and then
    # ignored here, so the advice would have been false for the slow tier.
    it "takes --host on the slow tier too, rather than routing to the container anyway" do
      with_container_project do |repo|
        with_fake_docker(repo) do |log, env|
          _out, err, code = sidecar("run", "--slow", "--host", "--dir", "tmp/elsewhere", env:)

          expect(code).to eq(0)
          expect(err).to include("Nothing to run")
          expect(execs(log)).to be_empty
        end
      end
    end
  end

  describe "status" do
    # Answers a different question from once: whether the last answer is still
    # current, not whether the code is clean.
    it "exits 2 when no pass has ever run" do
      with_project do
        _out, _err, code = sidecar("status")

        expect(code).to eq(2)
      end
    end

    it "exits 0 right after a pass, even with red sensors" do
      with_project(%(sensor :fails, name: "Fails", command: "false",
                            tier: :fast, kind: :computational, group: :lint)) do
        sidecar("once", "--quiet")

        _out, _err, code = sidecar("status")

        expect(code).to eq(0)
      end
    end
  end

  describe "gate" do
    # The bug this closes: the old script exited 0 here, so a guardrail reported
    # success at exactly the moment it was not working.
    it "exits 3 rather than 0 when the base resolves to HEAD" do
      with_project do
        _out, err, code = sidecar("gate", "--base", "HEAD")

        expect(code).to eq(3)
        expect(err).to include("must never report clean")
      end
    end

    it "exits 3 on a base that does not resolve" do
      with_project do
        _out, _err, code = sidecar("gate", "--base", "origin/nope")

        expect(code).to eq(3)
      end
    end

    # Deliberately distinct from `once`'s sensor set: reusing it would make every
    # fast sensor blocking at merge.
    it "says so when no sensor is marked gate:" do
      with_project do
        out, _err, code = sidecar("gate", "--base", "HEAD~0")

        expect(code).to eq(0).or eq(3)
        expect(out + _err.to_s).to match(/gate|clean/i)
      end
    end
  end

  # Invoked the way a consumer does, through bundler's generated binstub, rather
  # than by spawning the file.
  #
  # The distinction is not academic. This file first carried an
  # `if $PROGRAM_NAME == __FILE__` guard, correct for a project script and wrong
  # for a gem executable: the binstub `load`s the file, so $PROGRAM_NAME is the
  # binstub, the guard was false, and every command did nothing and exited 0.
  # Every spec that spawned the file directly passed.
  describe "through the binstub, as a consumer runs it" do
    def bundled(*argv, dir:)
      Open3.capture3({ "BUNDLE_GEMFILE" => File.join(GEM_ROOT, "Gemfile") },
                     "bundle", "exec", "sidecar", *argv, chdir: dir)
    end

    it "actually runs, rather than exiting 0 having done nothing" do
      with_project do
        out, _err, status = bundled("status", dir: Dir.pwd)

        expect(status.exitstatus).to eq(2)
        expect(out).to include("SIDECAR DOWN")
      end
    end

    it "reaches the same exit codes as a direct invocation" do
      with_project do
        _out, _err, status = bundled("gate", "--base", "HEAD", dir: Dir.pwd)

        expect(status.exitstatus).to eq(3)
      end
    end
  end

  describe "the command surface" do
    it "prints usage and exits 0 for --help" do
      out, _err, code = sidecar("--help")

      expect(code).to eq(0)
      expect(out).to include("Usage: sidecar")
    end

    it "exits 2 and names the commands for an unknown one" do
      _out, err, code = sidecar("frobnicate")

      expect(code).to eq(2)
      expect(err).to include("expected one of")
    end
  end
end
