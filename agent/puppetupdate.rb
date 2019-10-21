require 'fileutils'
require 'shellwords'

module MCollective
  module Agent
    class Puppetupdate < RPC::Agent
      attr_accessor :dir, :repo_url, :ignore_branches, :run_after_checkout,
                    :init_ignore_branches, :link_env_conf, :git_dir, :env_dir,
                    :lock_file, :expire_after_days, :dont_expire_branches

      def initialize
        @dir                  = config('directory', '/etc/puppet')
        @repo_url             = config('repository', 'http://git/puppet')
        @init_ignore_branches = config('init_ignore_branches', '').split(',').map { |i| regexy_string(i) }
        @ignore_branches      = config('ignore_branches', '').split(',').map { |i| regexy_string(i) }
        @run_after_checkout   = config('run_after_checkout', nil)
        @link_env_conf        = config('link_env_conf', false)
        @git_dir              = config('clone_at', "#{@dir}/puppet.git")
        @env_dir              = config('env_dir', "#{@dir}/environments")
        @lock_file            = config('lock_file', '/tmp/puppetupdate.lock')
        @expire_after_days    = config('expire_after_days', 30).to_i
        @dont_expire_branches = config('dont_expire_branches', '').split(',').map { |e| regexy_string(e) }
        super
      end


      action "update_all" do
        begin
          reply[:changes] = update_all_refs
          reply[:status] = "Done"
        rescue Exception => e
          reply.fail! "Exception: #{e}"
        end
      end

      action "update" do
        validate :revision, String
        validate :revision, :shellsafe
        validate :branch, String
        validate :branch, :shellsafe

        begin
          reply[:changes] = update_single_ref(request[:branch], request[:revision])
          reply[:status] = "Done"
        rescue Exception => e
          reply.fail! "Exception: #{e}"
        end
      end

      action "git_gc" do
        whilst_locked do
          run ["git --git-dir=%s gc --auto --prune", git_dir], "Pruning git repo"
        end
      end

      def init_refs()
        whilst_locked do
          ensure_dirs_and_fetch
          to_ignore = @ignore_branches + @init_ignore_branches
          resolve(git_state, env_state, ignore_branches=to_ignore)
        end
      end
      alias init_branches init_refs


      def update_all_refs
        whilst_locked do
          ensure_dirs_and_fetch
          resolve(git_state, env_state, ignore_branches=@ignore_branches)
        end
      end
      alias update_all_branches update_all_refs

      def update_single_ref(ref, revision=nil)
        whilst_locked do
          ensure_dirs_and_fetch
          revision = "#{revision}".empty? ? git_state[ref] : revision
          reset_ref(ref, revision).tap { |msg| Log.info msg }
        end
      end
      alias update_single_branch update_single_ref

      def git_cmd(cmd, *rest)
        ["git --git-dir=%s " << cmd, git_dir, *rest]
      end

      def ensure_dirs_and_fetch
        run ["mkdir -p %s", env_dir] unless File.directory?(env_dir)

        if run(git_cmd('config core.bare || echo false')).to_s.strip != "true"
          Log.warn("Invalid repo config in #{git_dir}, re-created")
          run ["rm -rf %s && mkdir -p %s", git_dir, git_dir]
          run git_cmd('init --bare')
        end

        config_repo_url = run(git_cmd('config remote.origin.url || echo false')).to_s.strip
        config_fetch = run(git_cmd('config remote.origin.fetch || echo false')).to_s.strip

        if config_repo_url != repo_url || config_fetch != "+refs/*:refs/*"
          Log.warn("Invalid remote config in #{git_dir} " <<
                   "(url: #{config_repo_url}, fetch: #{config_fetch}), re-created")
          run git_cmd("remote remove origin || true")
          run git_cmd("remote add origin --mirror=fetch %s", repo_url)
        end

        git_auth do
          run git_cmd("fetch --depth 1 --tags --prune origin"), "Fetching git repo"
        end
      end

      # Returns hash in form {refs => sha, ...}.
      def git_state
        if @git_state
          Log.info "Cached git state"
          @git_state
        else
          Log.info "Reading git state"
          ref_parse  = %r{^(\w+)\s+refs/(heads?|tags)/([\w/\-_]+)(\^\{\})?$}
          git_refs   = run(git_cmd("show-ref --dereference")).lines
          @git_state = git_refs.inject({}) do |agg, line|
            agg.merge!(line =~ ref_parse ? {$3 => $1} : {})
          end
        end
      end

      # Returns hash in form {dir => [ref, sha], ...}
      def env_state
        Log.info "Reading environment state"
        Dir.entries(env_dir).
          reject { |dir| %w{. ..}.include? dir }.
          inject({}) do |agg, dir|
            agg.merge!(
              dir => [ (File.read("#{env_dir}/#{dir}/.git_ref") rescue nil),
                       (File.read("#{env_dir}/#{dir}/.git_revision") rescue nil) ])
          end
      end

      # kinds of conflicts:
      # - ref exists in repo but not in env -> sync it
      # - ref exists in repo but not in correct state (wrong ref / sha) -> sync it
      # - ref exists in env but is to be removed -> remove
      # - ref exists in env but not in repo -> remove
      def resolve(git, env, ignore_branches=[])
        Log.info "Resolving changes"

        changes = []
        expiration_time = expire_after_days > 0 ?
                            Time.now.to_i - expire_after_days*24*3600 : 0

        Log.info "- inspecting env state: #{env.keys.size} deployed environments"
        env.each_pair do |dir, ref_sha|
          begin
            ref, sha = *ref_sha
            path = "#{env_dir}/#{dir}"

            if ref.nil? || sha.nil?
              if File.exists? path
                msg = "removed [#{dir} / #{ref} / #{sha}] (ref or sha = nil)"
                Log.info msg
                changes << msg
                run ["rm -rf %s", path]
              end
            elsif ignore_branches.any? {|r| dir =~ r || ref =~ r}
              Log.info "ignoring #{dir} / #{ref} - matches ignore_branches"
              if File.exists? path
                msg = "removed #{dir}"
                Log.info msg
                changes << msg
                run ["rm -rf %s", path]
              end
            elsif dir != ref_to_dir(ref)
              if File.exists? path
                msg = "removed #{dir} - #{ref_to_dir(ref)} != #{ref}"
                Log.info msg
                changes << msg
                run ["rm -rf %s", path]
              end
            elsif !git[ref]
              if File.exists? path
                msg = "removing #{dir} - gone from repo"
                Log.info msg
                changes << msg
                run ["rm -rf %s", path]
              end
            elsif sha != git[ref]
              msg = reset_ref(ref, git[ref])
              Log.info msg
              changes << msg
              git.delete ref
            elsif dont_expire_branches.none? {|r| dir =~ r || ref =~ r}  &&
                  File.exists?(path) &&
                  File.mtime("#{path}/.git_revision").to_i < expiration_time
              msg = "removing #{dir}: older than #{expire_after_days} days"
              Log.info msg
              changes << msg
              run ["rm -rf %s", path]
              git.delete ref
            else
              Log.debug "in-sync #{dir}"
              git.delete ref
            end
          rescue => err
            msg = "#{ref} env resolve: #{err.message} [#{err.backtrace.join ', '}]"
            Log.info msg
            changes << msg
          end
        end

        Log.info "- inspecting git state: #{git.keys.size} total refs"
        # by now git should only contain newly created refs
        git.each_pair do |ref, sha|
          begin
            dir  = ref_to_dir(ref)
            path = "#{env_dir}/#{dir}"

            if ref.nil? || sha.nil?
              if File.exists? path
                msg = "removed #{dir} - '#{ref}':'#{sha}' nils"
                Log.info msg
                changes << msg
                run ["rm -rf %s", path]
              end
            elsif ignore_branches.any? {|r| dir =~ r || ref =~ r}
              Log.info "ignoring #{dir} / #{ref} - matches ignore_branches"
              if File.exists? path
                run ["rm -rf %s", path]
                msg = "removed #{dir} / #{ref}"
                Log.info msg
                changes << msg
              end
            else
              time = run(git_cmd('show --quiet --format=format:%%at %s', ref)).to_i

              if dont_expire_branches.none? {|r| dir =~ r || ref =~ r} &&
                    time < expiration_time
                Log.info "not deploying #{dir}: older than #{expire_after_days} days"
              else
                msg = reset_ref(ref, sha)
                Log.info msg
                changes << msg
              end
            end
          rescue => err
            msg = "#{ref} env resolve: #{err.message} [#{err.backtrace.join ', '}]"
            Log.info msg
            changes << msg
          end
        end

        changes
      end

      def reset_ref(ref, revision, from=nil)
        from ||= File.read("#{ref_path(ref)}/.git_revision") rescue '00000000'

        if revision =~ /^0+$/
          work_tree = ref_path(ref)
          run ["rm -rf %s", work_tree]
          "#{ref}: deleted (was #{from[0..8]} in #{work_tree})"
        elsif from == revision
          "#{ref}: in sync @ #{revision[0..8]}"
        else
          fail "can't reset #{ref} to empty revision" if "#{revision}".empty?

          git_reset(ref, revision)
          linked = link_env_conf ? link_env_conf!(ref) : nil
          after_checkout = run_after_checkout!(ref)

          "#{ref}: #{from[0..8]}..#{revision[0..8]} in #{ref_to_dir(ref)}, " <<
            "linked env.conf: #{!!linked}, " <<
            "after checkout: #{after_checkout ? 'success' : 'fail (see logs)'}"
        end
      rescue => err
        "#{ref}: #{from}..#{revision} failed: " <<
          "#{err.message} [#{err.backtrace.join ', '}]"
      end

      def link_env_conf!(ref)
        if File.exists?(global_env_conf = "#{dir}/environment.conf") &&
           !File.exists?(local_env_conf = "#{ref_path(ref)}/environment.conf")
          run ["ln -s %s %s", global_env_conf, local_env_conf]
        end
      end

      def run_after_checkout!(ref)
        return nil unless run_after_checkout

        out = Dir.chdir(ref_path(ref)) { `#{run_after_checkout} 2>&1` }
        $?.success? || (Log.info "  after checkout failed: #{out}"; false)
      end

      def git_reset(ref, revision)
        work_tree = ref_path(ref)
        run ["mkdir -p %s", work_tree] unless File.exists?(work_tree)
        run git_cmd("--work-tree=%s checkout --detach --force %s", work_tree, revision)
        run git_cmd("--work-tree=%s clean -dxf", work_tree)
        File.write("#{work_tree}/.git_revision", revision)
        File.write("#{work_tree}/.git_ref", ref)
      end

      def ref_path(ref)
        "#{env_dir}/#{ref_to_dir(ref)}"
      end

      def ref_to_dir(ref)
        ref = ref.gsub /\//, '__'
        ref = ref.gsub /-/, '_'
        %w(master user agent main).include?(ref) ? "#{ref}branch" : ref
      end

      def git_auth
        if ssh_key = config('ssh_key')
          Dir.mktmpdir do |dir|
            wrapper_file = "#{dir}/ssh_wrapper.sh"
            File.open(wrapper_file, 'w', 0700) do |f|
              f.puts "#!/bin/sh"
              f.puts("exec /usr/bin/ssh -o StrictHostKeyChecking=no " <<
                     "-i #{ssh_key} \"$@\"")
            end

            begin
              old_git_ssh = ENV['GIT_SSH']
              ENV['GIT_SSH'] = wrapper_file
              yield
            ensure
              ENV['GIT_SSH'] = old_git_ssh
            end
          end
        else
          yield
        end
      end

      def run(cmd, msg=nil, level=:info)
        Log.send level, msg if msg
        cmd = "#{cmd.first % cmd[1..-1].map(&:shellescape)}" if cmd.is_a? Array
        output = `(#{cmd}) 2>&1`
        fail "#{cmd} failed: #{output}" unless $?.success?
        output
      end

      private

      def config(key, default = nil)
        Config.instance.pluginconf.fetch("puppetupdate.#{key}", default)
      rescue
        default
      end

      def whilst_locked
        File.open(lock_file, File::RDWR | File::CREAT, 0644) do |lock|
          lock.flock(File::LOCK_EX)
          yield
        end
      end

      def regexy_string(string)
        if string.match("^/")
          Regexp.new(string.gsub(/^\//, "").gsub(/\/$/, ""))
        else
          Regexp.new("^#{string}$")
        end
      end
    end
  end
end
