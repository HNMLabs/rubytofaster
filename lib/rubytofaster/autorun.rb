# frozen_string_literal: true

require_relative "../rubytofaster"

# Zero-configuration 1-line script runner:
#   #!/usr/bin/env ruby
#   require "rubytofaster/autorun"
caller_file = caller_locations(1, 5)&.map(&:absolute_path)&.compact&.find do |path|
  path != __FILE__ && !path.end_with?("/rubygems/core_ext/kernel_require.rb") && File.file?(path)
end
caller_file ||= $PROGRAM_NAME if $PROGRAM_NAME && File.file?($PROGRAM_NAME)
target_root = caller_file ? File.dirname(File.expand_path(caller_file)) : Dir.pwd

# Allow `require "rubytofaster/autorun"` to execute cleanly across repeated `rtf watch` cycles
# and multi-gem `Workspace` loads in the same Ruby VM process.
$LOADED_FEATURES.delete(__FILE__)
$LOADED_FEATURES.delete(File.realpath(__FILE__)) if File.exist?(__FILE__)

RubyToFaster.build(root_dir: target_root)
