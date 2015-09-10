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
      expect(Log).to receive(:info).with(/inspecting/).twice
    end

    context 'env resolutions' do
      it 'removes when ref is nil' do
        expect(Log).to receive(:info).with(/removing/).once
        agent.resolve({}, {"dir" => [nil, "sha"]})
      end

      it 'removes when sha is nil' do
        expect(Log).to receive(:info).with(/removing/)
        agent.resolve({}, {"dir" => ["ref"]})
      end

      it 'ignores when dir matches ignore_branches' do
        allow(agent).to receive(:ignore_branches).and_return([/dir/])
        expect(Log).to receive(:info).with(/ignoring dir/)
        agent.resolve({}, {"dir" => ["ref", "sha"]})
      end

      it 'ignores when ref matches ignore_branches'
      it 'removes when dir matches remove_branches'
      it 'removes when ref matches remove_branches'
      it 'removes when dir doesnt match ref_path(ref)'
      it 'removes when ref not found in git refs'
      it 'resets when sha doesnt match git ref'
      it 'noops in happy case'
    end

    context 'git resolutions' do
      it 'removes when ref is nil'
      it 'removes when sha is nil'
      it 'ignores when dir matches ignore_branches'
      it 'ignores when ref matches ignore_branches'
      it 'removes when dir matches remove_branches'
      it 'removes when ref matches remove_branches'
      it 'syncs in happy case'
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
      agent.stubs(:git_reset => nil,
                  :link_env_conf => false,
                  :run_after_checkout => false)
      File.expects(:read).raises
      agent.reset_ref('master', 'master')[1].should eq('000000')
    end

    it 'calls git_reset with correct args' do
      agent.stubs(:link_env_conf => false,
                  :run_after_checkout => false)
      agent.expects(:git_reset).with do |a,b|
        a.should eq('ref')
        b.should eq('rev')
      end

      agent.reset_ref('ref', 'rev', 'from')
    end

    it 'calls link_env_conf as per config' do
      agent.stubs(:git_reset => nil,
                  :link_env_conf => true,
                  :run_after_checkout => false)
      agent.expects(:link_env_conf!)
      agent.reset_ref('ref', 'rev', 'from')
    end

    it 'calls run_after_checkout as per config' do
      agent.stubs(:git_reset => nil,
                  :link_env_conf => false,
                  :run_after_checkout => true)
      agent.expects(:run_after_checkout!)
      agent.reset_ref('ref', 'rev', 'from')
    end

    it 'returns array in form [to, from, rev, link, after]' do
      agent.stubs(:git_reset => nil,
                  :link_env_conf => true,
                  :link_env_conf! => "link",
                  :run_after_checkout => true,
                  :run_after_checkout! => "run")
      File.stubs(:read => "from")
      agent.reset_ref('ref', 'rev').should(
        eq(%w{ref from rev link run}))
    end
  end

  describe '#git_reset' do
    let(:path) { agent.ref_path 'master' }

    it 'creates work tree dir' do
      system "rm -rf #{path}"
      agent.git_reset('master', 'master')
      File.exists?(path).should be_true
    end

    it 'checksout repo into work tree' do
      agent.git_reset('master', 'master')
      File.read("#{path}/initial").should eq("initial\n")
    end

    it 'cleans work tree' do
      system("mkdir -p #{path}")
      File.write("#{path}/dirty", "dirty")
      agent.git_reset('master', 'master', path)
      File.exists?("#{path}/dirty").should be_false
    end

    it 'creates .git_revision and .git_ref' do
      agent.git_reset('something', 'master', path)
      File.read("#{path}/.git_revision").should eq("master")
      File.read("#{path}/.git_ref").should eq("something")
    end
  end

  describe '#ref_path' do
    it 'is env_dir plus ref_to_dir' do
      agent.expects(:env_dir).twice
      agent.expects(:ref_to_dir).with('master').returns('masterbranch')
      agent.ref_path('master').should eq("#{agent.env_dir}/masterbranch")
    end
  end

  describe '#ref_to_dir' do
    it 'replaces / with __' do
      agent.branch_dir('fo/bar').should eq('fo__bar')
    end

    it 'returns original name if its good' do
      agent.branch_dir('foobar').should eq('foobar')
    end

    it 'appends "branch" when reserved name' do
      agent.branch_dir('master').should eq('masterbranch')
      agent.branch_dir('user').should   eq('userbranch')
      agent.branch_dir('agent').should  eq('agentbranch')
      agent.branch_dir('main').should   eq('mainbranch')
    end
  end

  describe '#git_auth' do
    it 'creates ssh wrapper' do
      agent.stubs(:config => "hello")
      agent.git_auth do
        File.exists?(ENV['GIT_SSH']).should be(true)
        File.read(ENV['GIT_SSH']).should match(/hello/m)
      end
    end

    it 'cleans up after yield' do
      agent.stubs(:config => "hello")
      file_name = agent.git_auth { ENV['GIT_SSH'] }
      File.exists?(file_name).should be(false)
    end

    it 'sets env var yields and restores env' do
      agent.stubs(:config => "hello")
      with_git_ssh('not_matching') do
        agent.git_auth { ENV['GIT_SSH'].should match(/ssh_wrapper/) }
      end
    end

    it 'yields without touching env without ssh_key' do
      agent.stubs(:config => nil)
      with_git_ssh('anything') do
        agent.git_auth { ENV['GIT_SSH'].should eq('anything') }
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
      agent.run("echo hello").should eq("hello\n")
    end

    it 'redirects err to out' do
      agent.run("(echo hello >&2)").should eq("hello\n")
    end

    it 'fails with message' do
      agent.expects(:fail).returns nil
      agent.run("false")
    end
  end

  describe '#whilst_locked' do
    it 'uses lock_file config value' do
      agent.expects(:lock_file).returns("lock")
      File.expects(:open).with {|arg1| arg1 == "lock"}
      agent.send(:whilst_locked) {}
    end

    it 'creates lock file and locks it' do
      lock_stub = stub
      lock_stub.expects(:flock)
      File.expects(:open).yields(lock_stub)
      agent.send(:whilst_locked) {}
    end

    it 'returns yielded result' do
      expect { agent.send(:whilst_locked) { "hello" }.to eq("hello")}
    end
  end

  describe '#regexy_string' do
    it 'wraps generic string in ^$' do
      agent.send(:regexy_string, "hi").should == /^hi$/
    end

    it 'recognizes regexy string' do
      agent.send(:regexy_string, "/hi/").should == /hi/
    end
  end

  # OLD

  it "#branches_in_repo_to_sync works" do
    agent.stubs(:git_state => {'foo' => nil, 'bar' => nil, 'leave_me_alone' => nil})
    agent.branches_in_repo_to_sync.should == ['foo', 'bar']
  end

  it "#branch_dir is not using reserved branch" do
  end

  describe "#update_bare_repo" do
    before { clean && clone_main }

    it "clones fresh repository" do
      agent.update_bare_repo
      File.directory?(agent.git_dir).should be true
      agent.git_refs_hash.size.should be > 1
    end

    it "fetches repository when present" do
      clone_bare
      agent.update_bare_repo
      File.directory?(agent.git_dir).should be true
      agent.git_refs_hash.size.should be > 1
    end
  end

  it '#drop_bad_dirs removes branches no longer in repo' do
    `mkdir -p #{agent.env_dir}/hahah`
    agent.drop_bad_dirs
    File.exist?("#{agent.env_dir}/hahah").should == false
  end

  it '#drop_bad_dirs does not remove ignored branches' do
    `mkdir -p #{agent.env_dir}/leave_me_alone`
    agent.drop_bad_dirs
    File.exist?("#{agent.env_dir}/leave_me_alone").should == true
  end

  it '#drop_bad_dirs does cleanup removed branches' do
    `mkdir -p #{agent.env_dir}/must_be_removed`
    agent.drop_bad_dirs
    File.exist?("#{agent.env_dir}/must_be_removed").should == false
  end

  it 'checks out an arbitrary Git hash from a fresh repo' do
    agent.update_single_branch("master")
    previous_rev = `cd #{agent.dir}/puppet.git; git rev-list master --max-count=1 --skip=1`.chomp
    File.write("#{agent.env_dir}/masterbranch/touch", "touch")
    agent.update_single_branch("master", previous_rev)
    File.exist?("#{agent.env_dir}/masterbranch/initial").should == true
    File.exist?("#{agent.env_dir}/masterbranch/touch").should == false
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
      agent.dirs_in_env_dir.include?('testing_del_branch').should == true

      del_branch 'testing_del_branch'
      agent.update_bare_repo
      agent.dirs_in_env_dir.include?('testing_del_branch').should == true

      agent.update_single_branch 'testing_del_branch'
      agent.drop_bad_dirs
      agent.dirs_in_env_dir.include?('testing_del_branch').should == false
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
