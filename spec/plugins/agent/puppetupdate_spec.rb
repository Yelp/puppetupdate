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
require 'test/unit'
require 'yaml'
require 'tmpdir'
require 'spec_helper'
require 'agent/puppetupdate'

describe MCollective::Agent::Puppetupdate do
  attr_accessor :agent

  before(:all) do
    @agent = MCollective::Test::LocalAgentTest.new(
      "puppetupdate",
      :agent_file => "#{File.dirname(__FILE__)}/../../../agent/puppetupdate.rb",
      :config     => {
        "plugin.puppetupdate.directory" => Dir.mktmpdir,
        "plugin.puppetupdate.repository" => Dir.mktmpdir,
        "plugin.puppetupdate.lock_file" => "/tmp/puppetupdate_spec.lock",
        "plugin.puppetupdate.ignore_branches" => "/^leave_me_alone$/",
        "plugin.puppetupdate.remove_branches" => "/^must/"}).plugin

    repo_dir = agent.repo_url
    system <<-SHELL
      ( cd #{repo_dir}
        git init --bare

        cd #{Dir.mktmpdir}
        git clone #{repo_dir} .
        echo initial > initial
        git add initial
        git commit -m initial
        git push origin master

        git checkout -b branch1
        git push origin branch1

        git checkout -b must_be_removed
        git push origin must_be_removed) >/dev/null 2>&1
    SHELL

    clean
    clone_main
    clone_bare
    Dir.mkdir(agent.env_dir)

    agent.update_all_branches
  end

  after(:all) do
    system <<-SHELL
      rm -rf #{agent.dir}
      rm -rf #{agent.repo_url}
    SHELL
  end

  it "#branches_in_repo_to_sync works" do
    agent.stubs(:git_refs_hash => {'foo' => nil, 'bar' => nil, 'leave_me_alone' => nil})
    agent.branches_in_repo_to_sync.should == ['foo', 'bar']
  end

  it "#branch_dir is not using reserved branch" do
    agent.branch_dir('fo/bar').should eq('fo__bar')
    agent.branch_dir('foobar').should eq('foobar')
    agent.branch_dir('master').should eq('masterbranch')
    agent.branch_dir('user').should   eq('userbranch')
    agent.branch_dir('agent').should  eq('agentbranch')
    agent.branch_dir('main').should   eq('mainbranch')
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
    `rm -rf #{agent.dir}`
  end

  def clone_main
    `git clone -q #{agent.repo_url} #{agent.dir}`
  end

  def clone_bare
    `git clone -q --mirror #{agent.repo_url} #{agent.git_dir}`
  end

  def new_branch(name)
    tmp_dir = Dir.mktmpdir
    system <<-SHELL
      ( git clone #{agent.repo_url} #{tmp_dir} &&
        cd #{tmp_dir} &&
        git checkout -b #{name} &&
        git push origin #{name} ) >/dev/null 2>&1
    SHELL
  end

  def del_branch(name)
    tmp_dir = Dir.mktmpdir
    system <<-SHELL
      git clone #{agent.repo_url} #{tmp_dir} >/dev/null 2>&1;
      cd #{tmp_dir};
      git push origin :#{name} >/dev/null 2>&1
    SHELL
  end
end
