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
          update_all_branches
          reply[:output] = "Done"
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
          ret = update_single_branch(request[:branch], request[:revision])
          if ret
            reply[:status] = "Done"
            [:from, :to].each { |s| reply[s] = ret[s] }
          else
            reply[:status] = "Deleted"
          end
        rescue Exception => e
          reply.fail! "Exception: #{e}"
        end
      end

      action "git_gc" do
        run "git --git-dir=#{git_dir} gc --auto --prune"
      end

      def update_all_branches
        whilst_locked do
          updated_refs = update_bare_repo
          drop_bad_dirs
          branches_in_repo_to_sync.each {|branch| update_branch(branch) }
        end
      end

      def update_single_branch(branch, revision='')
        whilst_locked do
          update_bare_repo
          drop_bad_dirs
          update_branch(branch, revision)
        end
      end

      # only updates branch if it has to be kept in sync
      def update_branch(branch, revision='')
        return unless branches_in_repo_to_sync.include?(branch)
        Log.info "updating #{branch}"

        branch_path = "#{env_dir}/#{branch_dir(branch)}/"
        Dir.mkdir(env_dir) unless File.exist?(env_dir)
        Dir.mkdir(branch_path) unless File.exist?(branch_path)

        ret = git_reset(revision.length > 0 ? revision : branch, branch_path)

        if link_env_conf &&
           File.exists?(global_env_conf = "#{dir}/environment.conf") &&
           !File.exists?(local_env_conf = "#{branch_path}/environment.conf")
          run "ln -s #{global_env_conf} #{local_env_conf}"
          Log.info "  linked #{global_env_conf} -> #{local_env_conf}"
        end

        if run_after_checkout
          Dir.chdir(branch_path) { ret[:after_checkout] = system run_after_checkout }
          Log.info "  after checkout is #{ret[:after_checkout]}"
        end
        ret
      end

      REF_MATCH=%r{refs/(heads|(tags.*\^))}
      REF_PARSE=%r{^(\w+)\s+refs/(heads|tags)/(\w+)(\^\{\})?$}

      def git_refs_hash
        `git --work-tree=#{git_dir} show-ref --dereference 2>/dev/null`.lines.
          inject({}) {|agg, line| agg.merge!(line =~ REF_PARSE ? {$3 => $1} : {})}
      end

      def update_bare_repo
        git_auth do
          if File.exists?(git_dir)
            Log.info "fetching #{git_dir}"
            before_refs = git_refs_hash
            run "git --git-dir=#{git_dir} fetch --tags --prune"
            git_refs_hash.select{|k,v| before_refs[k] != v}.map(&:first)
          else
            Log.info "cloning #{@repo_url} into #{git_dir}"
            run "git clone --mirror #{@repo_url} #{git_dir}"
            git_refs_hash.keys
          end
        end
      end

      def drop_bad_dirs
        dirs_in_env_dir_to_drop.each do |dir|
          Log.info "removing #{dir}"
          run "rm -rf '#{env_dir}/#{dir}'"
        end
      end

      # all actual branches in repo; this method is cached
      def branches_in_repo
        %x[cd #{git_dir} && git branch -a].lines.
          map {|l| l.gsub(/^\s*\*/, '').strip}.
          reject {|b| b =~ /no branch/ || b =~ /detached from/}
      end

      # we want to sync branches that are not ignored and are
      # not going to be removed
      def branches_in_repo_to_sync
        branches_in_repo.reject do |branch|
          remove_branches.any? { |r| r.match(branch) } or
          ignore_branches.any? { |r| r.match(branch) }
        end
      end

      def dirs_in_env_dir
        Dir.entries(env_dir).reject {|e| ['.', '..'].include? e}
      end

      # we want to remove dirs that are not corresponding to branches
      # kept in sync and not those that should be ignored
      def dirs_in_env_dir_to_drop
        (dirs_in_env_dir - branches_in_repo_to_sync.map {|b| branch_dir b}).
          reject { |branch| ignore_branches.any? { |r| r.match(branch) } }
      end

      def git_reset(revision, work_tree)
        from = File.exist?("#{work_tree}/.git_revision") ? run("cat #{work_tree}/.git_revision").chomp : 'unknown'
        run "git --git-dir=#{git_dir} --work-tree=#{work_tree} checkout --detach --force #{revision}"
        run "git --git-dir=#{git_dir} --work-tree=#{work_tree} clean -dxf"
        to = run "git --git-dir=#{git_dir} --work-tree=#{work_tree} rev-parse HEAD"
        File.open("#{work_tree}/.git_revision", 'w') { |f| f.puts to }
        { :from => from, :to => to }
      end

      def branch_dir(branch)
        branch = branch.gsub /\//, '__'
        branch = branch.gsub /-/, '_'
        %w(master user agent main).include?(branch) ? "#{branch}branch" : branch
      end

      def git_auth
        if ssh_key = config('ssh_key')
          Dir.mktmpdir do |dir|
            wrapper_file = "#{dir}/ssh_wrapper.sh"
            File.open(wrapper_file, 'w') do |f|
              f.print "#!/bin/sh\n"
              f.print "exec /usr/bin/ssh -o StrictHostKeyChecking=no -i #{ssh_key} \"$@\"\n"
            end
            File.chmod(0700, wrapper_file)
            ENV['GIT_SSH'] = wrapper_file
            yield
            ENV.delete 'GIT_SSH'
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
        ret = nil
        File.open(lock_file, File::RDWR | File::CREAT, 0644) do |lock|
          lock.flock(File::LOCK_EX)
          ret = yield
        end
        ret
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
