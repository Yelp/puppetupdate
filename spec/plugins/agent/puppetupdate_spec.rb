#! /usr/bin/env ruby -S rspec
$: << '.'
require 'singleton'
require 'mcollective/logger'
require 'mcollective/log'
require 'mcollective/config'
require 'mcollective/pluginmanager'
require 'mcollective/agent'
require 'mcollective/rpc'
require 'mcollective/rpc/agent'
require 'mcollective/cache'
require 'mcollective/ddl'
require 'yaml'
require 'tmpdir'
require 'spec_helper'
require 'agent/puppetupdate'

describe MCollective::Agent::Puppetupdate do
  Log = MCollective::Log
  attr_accessor :agent

  def repo_dir; @repo_url ||= Dir.mktmpdir; end
  def agent_dir; @agent_dir ||= Dir.mktmpdir; end

  let(:agent) do
    MCollective::Test::LocalAgentTest.new(
      "puppetupdate",
      :agent_file => "#{File.dirname(__FILE__)}/../../../agent/puppetupdate.rb",
      :config     => {
        "logger_type" => "console",
        "plugin.puppetupdate.directory" => agent_dir,
        "plugin.puppetupdate.repository" => repo_dir,
        "plugin.puppetupdate.lock_file" => "#{agent_dir}/puppetupdate_spec.lock",
        "plugin.puppetupdate.ignore_branches" => "/^leave_me_alone$/",
        "plugin.puppetupdate.init_ignore_branches" => "/^ignore_on_init$/",
        "plugin.puppetupdate.dont_expire_branches" => "keep_me_1,keep_me_2",
        "plugin.puppetupdate.expire_after_days" => "30"}).plugin
  end

  before(:all) do
    system <<-SHELL
      ( cd #{repo_dir}
        git init --bare

        TMP_REPO=#{Dir.mktmpdir}
        cd $TMP_REPO
        git clone #{repo_dir} .
        git config user.email root@root
        git config user.name root
        echo initial > initial
        git add initial
        git commit -m initial
        git push origin master

        git checkout -b branch1
        git push origin branch1

        git checkout -b must_be_removed
        git push origin must_be_removed
        rm -rf $TMP_REPO) 2>&1
    SHELL

    `rm -rf #{agent_dir}`
    `git clone -q #{repo_dir} #{agent_dir}`
    `git clone -q --mirror #{repo_dir} #{agent_dir}/puppet.git`
  end

  after(:all) do
    system <<-SHELL
      rm -rf #{agent_dir}
      rm -rf #{repo_dir}
    SHELL
  end

  describe '#update_all_refs' do
    it 'locks the agent' do
      expect(agent).to receive(:whilst_locked)
      agent.update_all_refs
    end

    it 'fetches the repo and init' do
      expect(agent).to receive(:whilst_locked).and_yield
      expect(agent).to receive(:ensure_dirs_and_fetch)
      expect(agent).to receive(:git_state).and_return(:git)
      expect(agent).to receive(:env_state).and_return(:env)
      expect(agent).to receive(:resolve).with(:git, :env, [/^leave_me_alone$/, /^ignore_on_init$/])
      agent.init_refs
    end


    it 'fetches the repo and updates all' do
      expect(agent).to receive(:whilst_locked).and_yield
      expect(agent).to receive(:ensure_dirs_and_fetch)
      expect(agent).to receive(:git_state).and_return(:git)
      expect(agent).to receive(:env_state).and_return(:env)
      expect(agent).to receive(:resolve).with(:git, :env, [/^leave_me_alone$/])
      agent.update_all_refs
    end
  end

  describe '#update_single_ref' do
    it 'locks the agent' do
      expect(agent).to receive(:whilst_locked)
      agent.update_all_refs
    end

    it 'fetches the repo and updates single' do
      expect(agent).to receive(:whilst_locked).and_yield
      expect(agent).to receive(:ensure_dirs_and_fetch)
      expect(agent).to receive(:git_state).and_return('ref' => 'rev')
      expect(agent).to receive(:reset_ref).with('ref', 'rev')
      agent.update_single_ref('ref', '')
    end
  end

  describe '#ensure_dirs_and_fetch' do
    it 'ensures env_dir exists' do
      allow(agent).to receive(:run)
      expect(File).to receive(:directory?).with(agent.env_dir).and_return(false)
      expect(agent).to receive(:run).with(["mkdir -p %s", agent.env_dir])
      agent.ensure_dirs_and_fetch
    end

    it 're-creates repo whith bad state' do
      agent.run("rm -rf #{agent.git_dir}/*")
      expect(Log).to receive(:warn).with(/Invalid repo/)
      expect(Log).to receive(:warn).with(/Invalid remote/)
      agent.ensure_dirs_and_fetch
    end

    it 're-creates remote when bad url' do
      expect(Log).to receive(:warn).with(/Invalid remote/)
      remote_conf = "git --git-dir=#{agent.git_dir} config remote.origin.url"
      agent.run("#{remote_conf} localhost")
      expect(agent.run remote_conf).to eq("localhost\n")
      agent.ensure_dirs_and_fetch
      expect(agent.run remote_conf).to eq("#{agent.repo_url}\n")
    end

    it 're-creates remote when not mirror' do
      expect(Log).to receive(:warn).with(/Invalid remote/)
      remote_conf = "git --git-dir=#{agent.git_dir} config remote.origin.fetch"
      agent.run("#{remote_conf} bad-fetch")
      agent.ensure_dirs_and_fetch
    end
  end

  describe '#git_state' do
    it 'returns a hash with git refs => git shas' do
      expect(agent.git_state.keys).to eq(%w{branch1 master must_be_removed})
    end
  end

  describe '#env_state' do
    it 'returns a hash with proper contents' do
      allow(Dir).to receive(:entries).and_return(%w{. .. env})
      expect(File).to receive(:read).with(/\.git_ref/).and_return("ref")
      expect(File).to receive(:read).with(/\.git_rev/).and_return("rev")
      expect(agent.env_state).to eq("env" => %w{ref rev})
    end
  end

  describe '#resolve' do
    before(:each) do
      allow(Log).to receive(:info)
    end

    context 'env resolutions' do
      it 'removes when ref is nil' do
        expect(File).to receive(:exists?).and_return true
        expect(Log).to receive(:info).with(/removed/).once
        expect(agent).to receive(:run)
        agent.resolve({}, {"dir" => [nil, "sha"]})
      end

      it 'removes when sha is nil' do
        expect(File).to receive(:exists?).and_return true
        expect(Log).to receive(:info).with(/removed/)
        expect(agent).to receive(:run)
        agent.resolve({}, {"dir" => ["ref"]})
      end

      it 'ignores when dir matches ignore_branches' do
        expect(Log).to receive(:info).with(/ignoring dir/)
        expect(agent).to receive(:run).never
        agent.resolve({}, {"dir" => ["ref", "sha"]}, [/dir/])
      end

      it 'ignores when ref matches ignore_branches' do
        expect(Log).to receive(:info).with(/ignoring dir/)
        expect(agent).to receive(:run).never
        agent.resolve({}, {"dir" => ["ref", "sha"]}, [/ref/])
      end

      it 'removes when dir matches ignore_branches' do
        expect(File).to receive(:exists?).and_return true
        expect(Log).to receive(:info).with(/matches ignore/)
        expect(agent).to receive(:run)
        agent.resolve({}, {"dir" => ["ref", "sha"]}, [/dir/])
      end

      it 'removes when ref matches ignore_branches' do
        expect(File).to receive(:exists?).and_return true
        expect(Log).to receive(:info).with(/matches ignore/)
        expect(agent).to receive(:run)
        agent.resolve({}, {"dir" => ["ref", "sha"]}, [/ref/])
      end

      it 'removes when dir doesnt match ref_to_dir(ref)' do
        expect(File).to receive(:exists?).and_return true
        expect(Log).to receive(:info).with(/removed.*!=/)
        expect(agent).to receive(:run)
        agent.resolve({}, {"dir" => ["ref", "sha"]})
      end

      it 'removes when ref not found in git refs' do
        expect(File).to receive(:exists?).and_return true
        expect(Log).to receive(:info).with(/gone from repo/)
        expect(agent).to receive(:run)
        agent.resolve({}, {"dir" => ["dir", "sha"]})
      end

      it 'resets when sha doesnt match git ref' do
        expect(agent).to receive(:reset_ref).with('dir', 'sha2')
        git_state = {"dir" => "sha2"}
        env_state = {"dir" => ["dir", "sha1"]}
        changes = agent.resolve(git_state, env_state)
        expect(git_state).to be_empty
      end

      it 'no-ops in happy case' do
        # expect(Log).to receive(:info).with(/in-sync/)
        expect(agent).to receive(:reset_ref).never
        git_state = {"dir" => "sha1"}
        agent.resolve(git_state, {"dir" => ["dir", "sha1"]})
        expect(git_state).to be_empty
      end

      it 'removes deployment that is older than expiration' do
        expect(Log).to receive(:info).with(/older/)
        expect(File).to receive(:exists?).and_return(true)
        expect(File).to receive(:mtime).and_return(Time.now.to_i - 31*24*3600)
        expect(agent).to receive(:run).with([/rm -rf/, /dir/])
        agent.resolve({"dir" => "sha1"}, {"dir" => ["dir", "sha1"]})
      end

      it 'keeps deployment that is older than expiration and is listed in dont_expire_branches' do
        allow(File).to receive(:exists?).and_return(true)
        allow(File).to receive(:mtime).and_return(Time.now.to_i - 31*24*3600)
        expect(Log).not_to receive(:info).with(/removing/)
        expect(agent).to receive(:run).never
        git_state = {"keep_me_2" => "sha1"}
        agent.resolve(git_state, {"keep_me_2" => ["keep_me_2", "sha1"]})
        expect(git_state).to be_empty
      end
    end

    context 'git resolutions' do
      it 'removes when sha is nil' do
        expect(Log).to receive(:info).with(/removed/)
        expect(File).to receive(:exists?).and_return(true)
        expect(agent).to receive(:run)
        agent.resolve({"ref" => nil}, {})
      end

      it 'ignores when ref matches ignore_branches' do
        expect(Log).to receive(:info).with(/matches ignore/)
        expect(agent).to receive(:run).never
        agent.resolve({"ref" => "sha"}, {}, [/ref/])
      end

      it 'ignores when dir matches ignore_branches' do
        allow(agent).to receive(:ref_to_dir).and_return("dir")
        expect(Log).to receive(:info).with(/matches ignore/)
        expect(agent).to receive(:run).never
        agent.resolve({"ref" => "sha"}, {}, [/dir/])
      end

      it 'removes when dir matches ignore_branches' do
        expect(File).to receive(:exists?).and_return true
        expect(Log).to receive(:info).with(/removed ref/)
        expect(agent).to receive(:run)
        agent.resolve({"ref" => "sha"}, {}, [/ref/])
      end

      it 'removes when ref matches ignore_branches' do
        allow(agent).to receive(:ref_to_dir).and_return("dir")
        expect(File).to receive(:exists?).and_return true
        expect(Log).to receive(:info).with(/removed dir/)
        expect(agent).to receive(:run)
        agent.resolve({"ref" => "sha"}, {}, [/dir/])
      end

      it 'ignores old branches' do
        expect(Log).to receive(:info).with(//)
        expect(agent).to receive(:run).with([/show/, //, /ref/]).and_return Time.now.to_i-31*24*3600
        expect(agent).to receive(:reset_ref).never
        agent.resolve({"ref" => "sha"}, {})
      end

      it 'does not ignore old branches listed in dont_expire_branches' do
        expect(agent).to receive(:run).with([/show/, //, /keep_me_1/]).and_return Time.now.to_i-31*24*3600
        expect(Log).not_to receive(:info).with(/not deploying/)
        expect(agent).to receive(:reset_ref).with("keep_me_1", "sha1")
        agent.resolve({"keep_me_1" => "sha1"}, {})
      end

      it 'syncs in happy case' do
        expect(Log).to receive(:info).with(/deployed/)
        expect(agent).to receive(:run).with([/show/, //, /ref/]).and_return Time.now.to_i
        expect(agent).to receive(:reset_ref).with("ref", "sha")
        agent.resolve({"ref" => "sha"}, {})
      end
    end
  end

  describe '#reset_ref' do
    it 'reads current ref status if not passed' do
      allow(agent).to receive_messages(
        :git_reset => nil,
        )
      expect(File).to receive(:read).and_return('123')
      expect(agent.reset_ref('master', 'master')).to match(/123/)
    end

    it 'reports from as 0-commit if failed to read' do
      allow(agent).to receive_messages(
        :git_reset => nil,
        )
      expect(File).to receive(:read).and_raise
      expect(agent.reset_ref('master', 'master')).to match(/000000/)
    end

    it 'calls git_reset with correct args' do
      allow(agent).to receive_messages(
        :git_reset => nil,
        )
      expect(agent).to receive(:git_reset).with('ref', 'rev')
      agent.reset_ref('ref', 'rev', 'from')
    end

    it 'removes the environment when target is 00000000' do
      allow(agent).to receive(:run).with(["rm -rf %s", agent.ref_path('ref')])
      agent.reset_ref('ref', '00000000')
    end

    it 'noop when from == to' do
      allow(agent).to receive(:run).never
      allow(agent).to receive(:git_reset).never
      expect(agent.reset_ref('ref', '123', '123')).to eq("ref: in sync @ 123")
    end
  end

  describe '#git_reset' do
    let(:path) { agent.ref_path 'master' }

    it 'creates work tree dir and checkout repo' do
      system "rm -rf #{path}"
      agent.git_reset('master', 'master')
      expect(File.exists?(path)).to be_truthy
      expect(File.read("#{path}/initial")).to eq("initial\n")
    end

    it 'cleans work tree' do
      system("mkdir -p #{path}")
      File.write("#{path}/dirty", "dirty")
      agent.git_reset('master', 'master')
      expect(File.exists?("#{path}/dirty")).to be_falsy
    end

    it 'creates .git_revision and .git_ref' do
      allow(agent).to receive(:ref_path).and_return(path)
      agent.git_reset('ref', 'master')
      expect(File.read("#{path}/.git_revision")).to eq("master")
      expect(File.read("#{path}/.git_ref")).to eq("ref")
    end
  end

  describe '#ref_path' do
    it 'is env_dir plus ref_to_dir' do
      expect(agent).to receive(:env_dir).twice
      expect(agent).to receive(:ref_to_dir).with('master').
                         and_return('masterbranch')
      expect(agent.ref_path('master')).to eq("#{agent.env_dir}/masterbranch")
    end
  end

  describe '#ref_to_dir' do
    it 'replaces / with __' do
      expect(agent.ref_to_dir('fo/bar')).to eq('fo__bar')
    end

    it 'returns original name if its good' do
      expect(agent.ref_to_dir('foobar')).to eq('foobar')
    end

    it 'appends "branch" when reserved name' do
      expect(agent.ref_to_dir('master')).to eq('masterbranch')
      expect(agent.ref_to_dir('user')).to   eq('userbranch')
      expect(agent.ref_to_dir('agent')).to  eq('agentbranch')
      expect(agent.ref_to_dir('main')).to   eq('mainbranch')
    end
  end

  describe '#git_auth' do
    it 'creates ssh wrapper' do
      allow(agent).to receive(:config).and_return("hello")
      agent.git_auth do
        expect(File.exists?(ENV['GIT_SSH'])).to be(true)
        expect(File.read(ENV['GIT_SSH'])).to match(/hello/m)
      end
    end

    it 'cleans up after yield' do
      allow(agent).to receive(:config).and_return("hello")
      file_name = agent.git_auth { ENV['GIT_SSH'] }
      expect(File.exists?(file_name)).to be(false)
    end

    it 'sets env var yields and restores env' do
      allow(agent).to receive(:config).and_return("hello")
      with_git_ssh('not_matching') do
        agent.git_auth { expect(ENV['GIT_SSH']).to match(/ssh_wrapper/) }
      end
    end

    it 'yields without touching env without ssh_key' do
      allow(agent).to receive(:config).and_return(nil)
      with_git_ssh('anything') do
        agent.git_auth { expect(ENV['GIT_SSH']).to eq('anything') }
      end
    end

    def with_git_ssh(value)
      old_value = ENV['GIT_SSH']
      ENV['GIT_SSH'] = value
      yield
    ensure
      ENV['GIT_SSH'] = old_value
    end
  end

  describe '#run' do
    it 'returns output' do
      expect(agent.run("echo hello")).to eq("hello\n")
    end

    it 'redirects err to out' do
      expect(agent.run("(echo hello >&2)")).to eq("hello\n")
    end

    it 'fails with message' do
      expect(agent).to receive(:fail).and_return(nil)
      agent.run("false")
    end
  end

  describe '#whilst_locked' do
    it 'uses lock_file config value' do
      allow(agent).to receive(:lock_file).and_return("lock")
      expect(File).to receive(:open).with("lock", 66, 420)
      agent.send(:whilst_locked) {}
    end

    it 'creates lock file and locks it' do
      lock_stub = double
      expect(lock_stub).to receive(:flock)
      expect(File).to receive(:open).and_yield(lock_stub)
      agent.send(:whilst_locked) {}
    end

    it 'returns yielded result' do
      expect(agent.send(:whilst_locked) { "hello" }).to eq("hello")
    end
  end

  describe '#regexy_string' do
    it 'wraps generic string in ^$' do
      expect(agent.send(:regexy_string, "hi")).to eq(/^hi$/)
    end

    it 'recognizes regexy string' do
      expect(agent.send(:regexy_string, "/hi/")).to eq(/hi/)
    end
  end
end
