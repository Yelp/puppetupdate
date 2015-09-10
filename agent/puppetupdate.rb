require 'fileutils'

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
          reply[:changes] = update_single_ref(
            request[:branch],
            request[:revision] == '' ? nil : request[:revision])
          reply[:status] = "Done"
        rescue Exception => e
          reply.fail! "Exception: #{e}"
        end
      end

      action "git_gc" do
        run "git --git-dir=#{git_dir} gc --auto --prune"
      end

      def update_all_refs
        whilst_locked do
          ensure_repo_and_fetch
          resolve(git_state, env_state)
        end
      end

      def update_single_ref(ref, revision)
        whilst_locked do
          ensure_repo_and_fetch
          reset_ref(ref, revision == '' ? git_state[ref] : revision)
        end
      end

      def ensure_repo_and_fetch
        run "mkdir -p #{git_dir}"
        run "git --git-dir=#{git_dir} init --bare"
        run "git --git-dir=#{git_dir} remote remove origin"
        run "git --git-dir=#{git_dir} remote add --mirror=fetch origin #{repo_url}"
        run "git --git-dir=#{git_dir} fetch --tags --prune origin"
      end

      REF_PARSE=%r{^(\w+)\s+refs/(heads|tags)/(\w+)(\^\{\})?$}

      # Returns hash in form refs => sha.
      def git_state
        `git --git-dir=#{git_dir} show-ref --dereference 2>/dev/null`.lines.
          inject({}) {|agg, line| agg.merge!(line =~ REF_PARSE ? {$3 => $1} : {})}
      end

      # Returns hash in form dir => [ref, sha]
      def env_state
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
        Log.info "inspecting env state: #{env.keys.join ', '}"
        env.each_pair do |dir, ref_sha|
          ref, sha = *ref_sha
          path = "#{env_dir}/#{dir}"

          if ref.nil? || sha.nil?
            Log.info "removing #{dir} - ref: '#{ref}' sha: '#{sha}', nils"
            run "rm -rf #{path}"
          elsif ignore_branches.any? {|r| dir =~ r || ref =~ r}
            Log.info "ignoring #{dir} / #{ref} - matches ignore_branches"
          elsif remove_branches.any? {|r| dir =~ r || ref =~ r}
            Log.info "removing #{dir} - matches remove_branches"
            run "rm -rf #{path}"
          elsif dir != ref_to_dir(ref)
            Log.info "removing #{dir} - #{ref_to_dir(ref)} != #{ref}"
            run "rm -rf #{path}"
          elsif !git[ref]
            Log.info "removing #{dir} - gone from repo"
            run "rm -rf #{path}"
          elsif sha != git[ref]
            Log.info "syncing #{dir} - #{sha}..#{git[ref]}"
            reset_ref(ref, git[ref])
            git.delete ref
          else
            Log.info "synced #{dir}"
            git.delete ref
          end
        end

        Log.info "inspecting git state: #{git.keys.join ', '}"
        # by now git should only contain newly created refs
        git.each_pair do |ref, sha|
          dir  = ref_to_dir(ref)
          path = "#{env_dir}/#{dir}"

          if ref.nil? || sha.nil?
            Log.info "removing #{dir} - ref: '#{ref}' sha: '#{sha}'"
            run "rm -rf #{path}"
          elsif ignore_branches.any? {|r| dir =~ r || ref =~ r}
            Log.info "ignoring #{dir} - matches ignore_branches"
          elsif remove_branches.any? {|r| dir =~ r || ref =~ r}
            Log.info "removing #{dir} - matches remove_branches"
            run "rm -rf #{path}"
          else
            Log.info "deploying #{dir} - #{ref} / #{sha}"
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
          run("ln -s #{global_env_conf} #{local_env_conf}")
        end
      end

      def run_after_checkout!(ref)
        Dir.chdir(ref_path(ref)) { system(run_after_checkout) }.
          tap {|result| Log.info "  after checkout is #{result}" }
      end

      def git_reset(ref, revision)
        work_tree = ref_path(ref)
        run "mkdir -p #{work_tree}" unless File.exists?(work_tree)
        run "git --git-dir=#{git_dir} --work-tree=#{work_tree} checkout --detach --force #{revision}"
        run "git --git-dir=#{git_dir} --work-tree=#{work_tree} clean -dxf"
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

      def run(cmd)
        output = `#{cmd} 2>&1`
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
