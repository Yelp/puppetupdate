$: << File.join([File.dirname(__FILE__), "lib"])

require 'rubygems'
require 'rspec'
require 'mcollective/test'
require 'tempfile'

module MCollective::Test::Util::Validator
  def self.validate; false; end
end

RSpec.configure do |config|
  config.include(MCollective::Test::Matchers)
  config.before(:each) { MCollective::PluginManager.clear }
end
