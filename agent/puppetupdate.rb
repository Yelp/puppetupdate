require 'fileutils'
require 'shellwords'

module MCollective
  module Agent
    class Puppetupdate < RPC::Agent
      attr_accessor :dir, :repo_url, :ignore_branches, :run_after_checkout,
        :remove_branches, :link_env_conf, :git_dir, :env_dir, :lock_file

      def initialize
        @dir                = config('directory', '/etc/puppet')
        @repo_url           = config('repository', 'http://git/puppet')
        @ignore_branches    = config('ignore_branches', '').split(',').map { |i| regexy_string(i) }
        @remove_branches    = config('remove_branches', '').split(',').map { |r| regexy_string(r) }
        @run_after_checkout = config('run_after_checkout', nil)
        @link_env_conf      = config('link_env_conf', false)
        @git_dir            = config('clone_at', "#{@dir}/puppet.git")
        @env_dir            = config('env_dir', "#{@dir}/environments")
        @lock_file          = config('lock_file', '/tmp/puppetupdate.lock')
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
        run ["git --git-dir=%s gc --auto --prune", git_dir], "Pruning git repo"
      end

      def update_all_refs
        whilst_locked do
          ensure_dirs_and_fetch
          resolve(git_state, env_state)
        end
      end
      alias update_all_branches update_all_refs

      def update_single_ref(ref, revision=nil)
        whilst_locked do
          ensure_dirs_and_fetch
          reset_ref(ref, "#{revision}".empty? ? git_state[ref] : revision)
        end
      end
      alias update_single_branch update_single_ref

      def ensure_dirs_and_fetch
        run ["mkdir -p %s", env_dir] unless File.directory?(env_dir)
        g = "git --git-dir=#{git_dir.shellescape}"

        if `#{g} config core.bare 2>/dev/null`.strip != "true"
          Log.warn("Invalid repo config in #{git_dir}, re-created")
          run ["rm -rf %s && mkdir -p %s && #{g} init --bare", git_dir, git_dir]
        end

        if `#{g} config remote.origin.url 2>/dev/null`.strip != repo_url ||
           `#{g} config remote.origin.mirror 2>/dev/null`.strip != "true"
          Log.warn("Invalid remote config in #{git_dir}, re-created")
          run "#{g} remote remove origin || true"
          run ["#{g} remote add origin --mirror=fetch %s", repo_url]
        end

        git_auth do
          run "#{g} fetch --tags --prune origin", "Fetching git repo"
        end
      end

      # Returns hash in form refs => sha.
      def git_state
        if @git_state
          Log.info "Cached git state"
          @git_state
        else
          Log.info "Reading git state"
          ref_parse = %r{^(\w+)\s+refs/(heads?|tags)/([\w/-_]+)(\^\{\})?$}
          @git_state = `git --git-dir=#{git_dir.shellescape} show-ref \
                            --dereference 2>/dev/null`.lines.inject({}) do |agg, line|
            agg.merge!(line =~ ref_parse ? {$3 => $1} : {})
          end
        end
      end

      # Returns hash in form dir => [ref, sha]
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
      def resolve(git, env, limit=nil)
        Log.info "Resolving changes"

        Log.info "- inspecting env state: #{env.keys.size} deployed environments"
        env.each_pair do |dir, ref_sha|
          ref, sha = *ref_sha
          path = "#{env_dir}/#{dir}"

          if ref.nil? || sha.nil?
            if File.exists? path
              Log.info "  removing #{dir} / #{ref} / #{sha} - nils"
              run ["rm -rf %s", path]
            end
          elsif ignore_branches.any? {|r| dir =~ r || ref =~ r}
            Log.info "  ignoring #{dir} / #{ref} - matches ignore_branches"
          elsif remove_branches.any? {|r| dir =~ r || ref =~ r}
            if File.exists? path
              Log.info "  removing #{dir} - matches remove_branches"
              run ["rm -rf %s", path]
            end
          elsif dir != ref_to_dir(ref)
            if File.exists? path
              Log.info "  removing #{dir} - #{ref_to_dir(ref)} != #{ref}"
              run ["rm -rf %s", path]
            end
          elsif !git[ref]
            if File.exists? path
              Log.info "  removing #{dir} - gone from repo"
              run ["rm -rf %s", path]
            end
          elsif sha != git[ref]
            Log.info "  syncing #{dir} - #{sha}..#{git[ref]}"
            reset_ref(ref, git[ref])
            git.delete ref
          else
            Log.info "  synced #{dir}"
            git.delete ref
          end
        end

        Log.info "- inspecting git state: #{git.keys.size} total refs"
        # by now git should only contain newly created refs
        git.each_pair do |ref, sha|
          dir  = ref_to_dir(ref)
          path = "#{env_dir}/#{dir}"

          if ref.nil? || sha.nil?
            if File.exists? path
              Log.info "  removing #{dir} - '#{ref}':'#{sha}' nils"
              run ["rm -rf %s", path]
            end
          elsif ignore_branches.any? {|r| dir =~ r || ref =~ r}
            Log.info "  ignoring #{dir} / #{ref} - matches ignore_branches"
          elsif remove_branches.any? {|r| dir =~ r || ref =~ r}
            if File.exists? path
              Log.info "  removing #{dir} / #{ref} - matches remove_branches"
              run ["rm -rf %s", path]
            end
          else
            Log.info "  deploying #{dir} / #{ref} / #{sha}"
            reset_ref(ref, sha)
          end
        end
      end

      def reset_ref(ref, revision, from=nil)
        from ||= File.read("#{ref_path(ref)}/.git_revision") rescue '000000'
        git_reset(ref, revision)

        [ ref, from, revision,
          link_env_conf ? link_env_conf!(ref) : nil,
          run_after_checkout ? run_after_checkout!(ref) : nil ]
      end

      def link_env_conf!(ref)
        if File.exists?(global_env_conf = "#{dir}/environment.conf") &&
           !File.exists?(local_env_conf = "#{ref_path(ref)}/environment.conf")
          Log.info "  linked #{global_env_conf} -> #{local_env_conf}"
          run ["ln -s %s %s", global_env_conf, local_env_conf]
        end
      end

      def run_after_checkout!(ref)
        Dir.chdir(ref_path(ref)) { system(run_after_checkout) }.
          tap {|result| Log.info "  after checkout is #{result}" }
      end

      def git_reset(ref, revision)
        work_tree = ref_path(ref)
        run ["mkdir -p %s", work_tree] unless File.exists?(work_tree)
        run ["git --git-dir=%s --work-tree=%s checkout --detach --force %s", git_dir, work_tree, revision]
        run ["git --git-dir=%s --work-tree=%s clean -dxf", git_dir, work_tree]
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
        fail "#{cmd} failed with: #{output}" unless $?.success?
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
          Regexp.new(string.gsub("\/", ""))
        else
          Regexp.new("^#{string}$")
        end
      end
    end
  end
end
