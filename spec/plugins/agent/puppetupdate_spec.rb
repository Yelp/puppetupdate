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
        "plugin.puppetupdate.remove_branches" => "/^must/"}).plugin
  end

  before(:all) do
    system <<-SHELL
      ( cd #{repo_dir}
        git init --bare

        TMP_REPO=#{Dir.mktmpdir}
        cd $TMP_REPO
        git clone #{repo_dir} .
        echo initial > initial
        git add initial
        git commit -m initial
        git push origin master

        git checkout -b branch1
        git push origin branch1

        git checkout -b must_be_removed
        git push origin must_be_removed
        rm -rf $TMP_REPO) >/dev/null 2>&1
    SHELL

    clean
    clone_main
    clone_bare
  end

  after(:all) do
    system <<-SHELL
      rm -rf #{agent_dir}
      rm -rf #{repo_dir}
    SHELL
  end

  describe '#update_all_refs'

  describe '#update_single_ref'

  describe '#ensure_repo_and_fetch'

  describe '#git_state'

  describe '#env_state'

  describe '#resolve' do
    before(:each) do
      allow(Log).to receive(:info).with(/inspecting/)
    end

    context 'env resolutions' do
      it 'removes when ref is nil' do
        expect(Log).to receive(:info).with(/removing/).once
        expect(agent).to receive(:run)
        agent.resolve({}, {"dir" => [nil, "sha"]})
      end

      it 'removes when sha is nil' do
        expect(Log).to receive(:info).with(/removing/)
        expect(agent).to receive(:run)
        agent.resolve({}, {"dir" => ["ref"]})
      end

      it 'ignores when dir matches ignore_branches' do
        allow(agent).to receive(:ignore_branches).and_return([/dir/])
        expect(Log).to receive(:info).with(/ignoring dir/)
        expect(agent).to receive(:run).never
        agent.resolve({}, {"dir" => ["ref", "sha"]})
      end

      it 'ignores when ref matches ignore_branches' do
        allow(agent).to receive(:ignore_branches).and_return([/ref/])
        expect(Log).to receive(:info).with(/ignoring dir/)
        expect(agent).to receive(:run).never
        agent.resolve({}, {"dir" => ["ref", "sha"]})
      end

      it 'removes when dir matches remove_branches' do
        allow(agent).to receive(:remove_branches).and_return([/ref/])
        expect(Log).to receive(:info).with(/matches remove/)
        expect(agent).to receive(:run)
        agent.resolve({}, {"dir" => ["ref", "sha"]})
      end

      it 'removes when ref matches remove_branches' do
        allow(agent).to receive(:remove_branches).and_return([/ref/])
        expect(Log).to receive(:info).with(/matches remove/)
        expect(agent).to receive(:run)
        agent.resolve({}, {"dir" => ["ref", "sha"]})
      end

      it 'removes when dir doesnt match ref_to_dir(ref)' do
        expect(Log).to receive(:info).with(/removing.*!=/)
        expect(agent).to receive(:run)
        agent.resolve({}, {"dir" => ["ref", "sha"]})
      end

      it 'removes when ref not found in git refs' do
        expect(Log).to receive(:info).with(/gone from repo/)
        expect(agent).to receive(:run)
        agent.resolve({}, {"dir" => ["dir", "sha"]})
      end

      it 'resets when sha doesnt match git ref' do
        expect(Log).to receive(:info).with(/sha1\.\.sha2/)
        expect(agent).to receive(:reset_ref)
        git_state = {"dir" => "sha2"}
        agent.resolve(git_state, {"dir" => ["dir", "sha1"]})
        expect(git_state).to be_empty
      end

      it 'no-ops in happy case' do
        expect(Log).to receive(:info).with(/synced/)
        expect(agent).to receive(:run).never
        expect(agent).to receive(:reset_ref).never
        git_state = {"dir" => "sha1"}
        agent.resolve(git_state, {"dir" => ["dir", "sha1"]})
        expect(git_state).to be_empty
      end
    end

    context 'git resolutions' do
      it 'removes when sha is nil' do
        expect(Log).to receive(:info).with(/removing/)
        expect(File).to receive(:exists?).and_return(true)
        expect(agent).to receive(:run)
        agent.resolve({"ref" => nil}, {})
      end

      it 'ignores when dir matches ignore_branches' do
        allow(agent).to receive(:ignore_branches).and_return([/ref/])
        expect(Log).to receive(:info).with(/matches ignore/)
        expect(agent).to receive(:run).never
        agent.resolve({"ref" => "sha"}, {})
      end

      it 'ignores when ref matches ignore_branches' do
        allow(agent).to receive(:ignore_branches).and_return([/dir/])
        allow(agent).to receive(:ref_to_dir).and_return("dir")
        expect(Log).to receive(:info).with(/matches ignore/)
        expect(agent).to receive(:run).never
        agent.resolve({"ref" => "sha"}, {})
      end

      it 'removes when dir matches remove_branches' do
        allow(agent).to receive(:remove_branches).and_return([/ref/])
        expect(Log).to receive(:info).with(/matches remove/)
        expect(agent).to receive(:run)
        agent.resolve({"ref" => "sha"}, {})
      end

      it 'removes when ref matches remove_branches' do
        allow(agent).to receive(:remove_branches).and_return([/dir/])
        allow(agent).to receive(:ref_to_dir).and_return("dir")
        expect(Log).to receive(:info).with(/matches remove/)
        expect(agent).to receive(:run)
        agent.resolve({"ref" => "sha"}, {})
      end

      it 'syncs in happy case' do
        expect(Log).to receive(:info).with(/deploying/)
        expect(agent).to receive(:reset_ref).with("ref", "sha")
        agent.resolve({"ref" => "sha"}, {})
      end
    end
  end

  describe '#run_after_checkout!' do
    before { agent.update_all_refs }

    it 'chdirs into ref path' do
      expect(Dir).to receive(:chdir).with(agent.ref_path('master'))
      agent.run_after_checkout!('master')
    end

    it 'systems the callback and returns exit status' do
      allow(agent).to receive(:run_after_checkout).and_return("true")
      expect(agent.run_after_checkout!('master')).to be(true)
    end
  end

  describe '#link_env_conf!' do
    before { agent.update_all_refs }

    it 'with global without local' do
      agent.run "touch #{agent.dir}/environment.conf"
      agent.run "rm -f #{agent.ref_path('master')}/environment.conf"
      expect(agent).to receive(:run).and_return(nil)
      agent.link_env_conf!('master')
    end

    it 'with global with local' do
      agent.run "touch #{agent.dir}/environment.conf"
      agent.run "touch #{agent.ref_path('master')}/environment.conf"
      expect(agent).to receive(:run).never
      agent.link_env_conf!('master')
    end

    it 'without global with local' do
      agent.run "rm -f #{agent.dir}/environment.conf"
      agent.run "touch #{agent.ref_path('master')}/environment.conf"
      expect(agent).to receive(:run).never
      agent.link_env_conf!('master')
    end

    it 'without global without local' do
      agent.run "rm -f #{agent.dir}/environment.conf"
      agent.run "rm -f #{agent.ref_path('master')}/environment.conf"
      expect(agent).to receive(:run).never
      agent.link_env_conf!('master')
    end
  end

  describe '#reset_ref' do
    it 'reads current ref status if not passed' do
      allow(agent).to receive_messages(
        :git_reset => nil,
        :link_env_conf => false,
        :run_after_checkout => false)
      expect(File).to receive(:read).and_return('123')
      expect(agent.reset_ref('master', 'master')[1]).to eq('123')
    end

    it 'reports from as 0-commit if failed to read' do
      allow(agent).to receive_messages(
        :git_reset => nil,
        :link_env_conf => false,
        :run_after_checkout => false)
      expect(File).to receive(:read).and_raise
      expect(agent.reset_ref('master', 'master')[1]).to eq('000000')
    end

    it 'calls git_reset with correct args' do
      allow(agent).to receive_messages(
        :link_env_conf => false,
        :run_after_checkout => false)
      expect(agent).to receive(:git_reset).with('ref', 'rev')
      agent.reset_ref('ref', 'rev', 'from')
    end

    it 'calls link_env_conf as per config' do
      allow(agent).to receive_messages(
        :git_reset => nil,
        :link_env_conf => true,
        :run_after_checkout => false)
      expect(agent).to receive(:link_env_conf!)
      agent.reset_ref('ref', 'rev', 'from')
    end

    it 'calls run_after_checkout as per config' do
      allow(agent).to receive_messages(
        :git_reset => nil,
        :link_env_conf => false,
        :run_after_checkout => true)
      expect(agent).to receive(:run_after_checkout!)
      agent.reset_ref('ref', 'rev', 'from')
    end

    it 'returns array in form [to, from, rev, link, after]' do
      allow(agent).to receive_messages(
        :git_reset => nil,
        :link_env_conf => true,
        :link_env_conf! => "link",
        :run_after_checkout => true,
        :run_after_checkout! => "run")
      expect(File).to receive(:read).and_return("from")
      expect(agent.reset_ref('ref', 'rev')).to(
        eq(%w{ref from rev link run}))
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

  # OLD

  if false
  it "#branches_in_repo_to_sync works" do
    agent.stubs(:git_state => {'foo' => nil, 'bar' => nil, 'leave_me_alone' => nil})
    agent.branches_in_repo_to_sync.to == ['foo', 'bar']
  end

  describe "#update_bare_repo" do
    before { clean && clone_main }

    it "clones fresh repository" do
      agent.update_bare_repo
      File.directory?(agent.git_dir).to be true
      agent.git_refs_hash.size.to be > 1
    end

    it "fetches repository when present" do
      clone_bare
      agent.update_bare_repo
      File.directory?(agent.git_dir).to be true
      agent.git_refs_hash.size.to be > 1
    end
  end

  it '#drop_bad_dirs removes branches no longer in repo' do
    `mkdir -p #{agent.env_dir}/hahah`
    agent.drop_bad_dirs
    File.exist?("#{agent.env_dir}/hahah").to == false
  end

  it '#drop_bad_dirs does not remove ignored branches' do
    `mkdir -p #{agent.env_dir}/leave_me_alone`
    agent.drop_bad_dirs
    File.exist?("#{agent.env_dir}/leave_me_alone").to == true
  end

  it '#drop_bad_dirs does cleanup removed branches' do
    `mkdir -p #{agent.env_dir}/must_be_removed`
    agent.drop_bad_dirs
    File.exist?("#{agent.env_dir}/must_be_removed").to == false
  end

  it 'checks out an arbitrary Git hash from a fresh repo' do
    agent.update_single_branch("master")
    previous_rev = `cd #{agent.dir}/puppet.git; git rev-list master --max-count=1 --skip=1`.chomp
    File.write("#{agent.env_dir}/masterbranch/touch", "touch")
    agent.update_single_branch("master", previous_rev)
    File.exist?("#{agent.env_dir}/masterbranch/initial").to == true
    File.exist?("#{agent.env_dir}/masterbranch/touch").to == false
  end

  describe '#drop_bad_dirs' do
    it 'cleans up by default' do
      agent.expects(:run)
      `mkdir -p #{agent.env_dir}/hahah`
      agent.drop_bad_dirs
    end
  end

  describe 'updating deleted branch' do
    it 'does not fail and cleans up branch' do
      new_branch 'testing_del_branch'
      agent.update_single_branch 'testing_del_branch'
      agent.dirs_in_env_dir.include?('testing_del_branch').to == true

      del_branch 'testing_del_branch'
      agent.update_bare_repo
      agent.dirs_in_env_dir.include?('testing_del_branch').to == true

      agent.update_single_branch 'testing_del_branch'
      agent.drop_bad_dirs
      agent.dirs_in_env_dir.include?('testing_del_branch').to == false
    end
  end

  describe '#git_auth' do
    it 'sets GIT_SSH env from config' do
      agent.stubs(:config).with('ssh_key').returns('hello')
      agent.git_auth { expect(ENV['GIT_SSH']).to_not be_nil }
    end

    it 'yields directly when config is empty' do
      agent.stubs(:config).with('ssh_key').returns(nil)
      agent.git_auth { expect(ENV['GIT_SSH']).to be_nil }
    end
  end
  end

  def clean
    `rm -rf #{agent_dir}`
  end

  def clone_main
    `git clone -q #{repo_dir} #{agent_dir}`
  end

  def clone_bare
    `git clone -q --mirror #{repo_dir} #{agent_dir}/puppet.git`
  end

  def new_branch(name)
    tmp_dir = Dir.mktmpdir
    system <<-SHELL
      ( git clone #{agent.repo_url} #{tmp_dir} &&
        cd #{tmp_dir} &&
        git checkout -b #{name} &&
        git push origin #{name}
        rm -rf #{tmp_dir}) >/dev/null 2>&1
    SHELL
  end

  def del_branch(name)
    tmp_dir = Dir.mktmpdir
    system <<-SHELL
      ( git clone #{repo_dir} #{tmp_dir}
        cd #{tmp_dir}
        git push origin :#{name}
        rm -rf #{tmp_dir} ) >/dev/null 2>&1
    SHELL
  end
end
