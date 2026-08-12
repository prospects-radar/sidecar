# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "open3"

module Sidecar
  module SpecSupport
    # A real git repository, built per example, thrown away after.
    #
    # The changed-line gate shells out to `git diff` and `git ls-files`, and until
    # this existed nothing exercised that plumbing: the specs injected a fake in
    # its place, so the only untested code was the code the fake replaced. The
    # gate's refusal behaviour makes a fake impossible in principle — a fake
    # asked "does this base resolve?" would be asserting the thing under test.
    #
    # It also removes an accidental coupling. The gate filters candidate paths
    # through File.file? and reads real bytes to count lines, so specs written
    # against a fake still needed real files, and reached for whatever happened
    # to be lying around in the repository they ran inside.
    #
    # This helper is not shipped: `spec/` is absent from the gemspec's files, and
    # a shipped test helper would be a third public surface to version for a gem
    # with one consumer.
    module Repo
      # Builds a repository, chdirs into it, yields, and cleans up.
      #
      #   in_a_repo("app/x.rb" => "one\ntwo\n") do |repo|
      #     repo.commit("initial")
      #     repo.write("app/x.rb", "one\ntwo\nthree\n")
      #     ...
      #   end
      def in_a_repo(files = {})
        Dir.mktmpdir("sidecar-spec") do |dir|
          # macOS hands out /var/folders/... which is a symlink to /private/var.
          # git reports the resolved path, so an unresolved one here makes every
          # path comparison in a spec fail for a reason that has nothing to do
          # with the gate.
          dir = File.realpath(dir)
          Dir.chdir(dir) do
            builder = Builder.new(dir)
            builder.init
            files.each { |path, body| builder.write(path, body) }
            return yield(builder)
          end
        end
      end

      # Drives one fixture repository. Every method returns self except the
      # queries, so a fixture reads as a sequence of events.
      class Builder
        attr_reader :dir

        def initialize(dir)
          @dir = dir
        end

        def init
          # -c rather than `git config` so nothing here depends on, or disturbs,
          # the developer's global git configuration. gpgsign off because a
          # machine configured to sign would block on a passphrase prompt and
          # present as a hung suite.
          git("init", "--quiet", "--initial-branch=main")
          git("config", "user.email", "spec@example.com")
          git("config", "user.name", "Sidecar Spec")
          git("config", "commit.gpgsign", "false")
          self
        end

        def write(path, body)
          full = File.join(dir, path)
          FileUtils.mkdir_p(File.dirname(full))
          File.write(full, body)
          self
        end

        def delete(path)
          FileUtils.rm_f(File.join(dir, path))
          self
        end

        def add(*paths)
          git("add", *(paths.empty? ? [ "." ] : paths))
          self
        end

        def commit(message = "change", add: true)
          self.add if add
          git("commit", "--quiet", "--allow-empty", "-m", message)
          self
        end

        def branch(name)
          git("checkout", "--quiet", "-b", name)
          self
        end

        def checkout(ref)
          git("checkout", "--quiet", ref)
          self
        end

        def head = git("rev-parse", "HEAD").strip

        def ignore(*patterns)
          File.write(File.join(dir, ".gitignore"), "#{patterns.join("\n")}\n", mode: "a")
          self
        end

        # A clone too shallow to reach `base` — the state a CI checkout lands in
        # when `fetch --depth` undershoots the branch point.
        def shallow_clone_to(target, depth: 1)
          Builder.git_in(dir, "clone", "--quiet", "--depth", depth.to_s, "file://#{dir}", target)
          Builder.new(File.realpath(target))
        end

        def git(*argv) = Builder.git_in(dir, *argv)

        def self.git_in(dir, *argv)
          out, err, status = Open3.capture3("git", "-C", dir, *argv)
          raise "git #{argv.join(' ')} failed in #{dir}: #{err}" unless status.success?

          out
        end
      end
    end
  end
end
