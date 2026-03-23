# frozen_string_literal: true

# Parity testing helpers for asserting LiquidIL matches OG Liquid output,
# with optional recording of results as liquid-spec YAML files.
#
# == Usage
#
#   require_relative "helpers/parity_helper"
#
#   class MyTest < Minitest::Test
#     include ParityAssertions
#
#     def test_something
#       assert_parity_with_liquid_ruby("{{ x }}", { "x" => "hi" })
#     end
#   end
#
# == Recording specs
#
# Set LIQUID_IL_RECORD_SPECS=1 to capture every assert_parity_with_liquid_ruby
# call as a liquid-spec YAML entry. Results are written to test/specs/ at the
# end of the test run (one file per process, named by timestamp + PID).
#
#   LIQUID_IL_RECORD_SPECS=1 bundle exec rake test


require "digest"
require "yaml"
require "fileutils"
require "liquid"
require_relative "../../lib/liquid_il"

module SpecRecorder
  @recorded = []

  class << self
    def recording?
      ENV["LIQUID_IL_RECORD_SPECS"] == "1"
    end

    def record(test_name:, template:, expected:, environment: {}, filesystem: {})
      return unless recording?

      caller_location = caller_locations.find { |l| l.label.start_with?("test_") }
      caller_location ||= caller_locations.first

      @recorded << serialize_spec(
        name: test_name,
        template: template,
        expected: expected,
        environment: environment,
        filesystem: filesystem,
        caller_location: format_caller_location(caller_location),
      )
    rescue => e
      warn("⛔️ Error recording spec: #{e.message}\n#{e.backtrace.first(3).join("\n")}")
    end

    def finalize!
      return if @recorded.empty?

      timestamp = Time.now.strftime("%Y%m%d%H%M%S")
      dir = File.expand_path("../../specs", __FILE__)
      FileUtils.mkdir_p(dir)
      file_path = File.join(dir, "recorded_specs_#{timestamp}_#{Process.pid}.yml")
      @recorded.sort_by! { |spec| spec["name"] }
      File.write(file_path, @recorded.to_yaml)
      puts "\n\e[32m✓ Exported #{@recorded.size} specs to #{file_path}\e[0m"
      @recorded.clear
    end

    private

    def format_caller_location(location)
      location.to_s.delete_prefix("#{Dir.pwd}/").split(":")[0..1].join(":")
    end

    def serialize_spec(name:, template:, expected:, environment:, filesystem:, caller_location:)
      digest = Digest::SHA256.hexdigest([template, environment.to_yaml].join)[0..7]
      result = {
        "name" => "RecordedTest##{name}_#{digest}",
        "template" => template,
        "expected" => expected,
      }
      result["environment"] = deep_dup(environment) unless environment.nil? || environment.empty?
      result["filesystem"] = if filesystem.nil? || filesystem.empty?
        { "_error-message" => "This liquid context does not allow includes." }
      else
        deep_dup(filesystem)
      end
      result["caller_location"] = caller_location
      result.compact
    end

    def deep_dup(obj)
      Marshal.load(Marshal.dump(obj))
    end
  end
end

if defined?(Minitest)
  Minitest.after_run { SpecRecorder.finalize! }
else
  at_exit { SpecRecorder.finalize! }
end

# Mixin for tests that assert LiquidIL parity with OG Liquid.
# Renders the template with both engines, asserts they match,
# and records the result as a liquid-spec entry when LIQUID_IL_RECORD_SPECS=1.
module ParityAssertions
  # Assert LiquidIL produces the same output as OG Liquid.
  #
  # @param fs [Object, nil]  file system object (must expose @templates hash)
  #                          or a plain Hash of partial_name => source
  def assert_parity_with_liquid_ruby(template, assigns = {}, msg = nil, fs: nil)
    filesystem = extract_filesystem_hash(fs)

    og_env = fs ? Liquid::Environment.build { |e| e.file_system = fs } : nil
    og_opts = og_env ? { environment: og_env } : {}
    og_result = Liquid::Template.parse(template, **og_opts).render(assigns)

    il_ctx = LiquidIL::Context.new(file_system: fs)
    il_result = il_ctx.render(template, assigns)

    SpecRecorder.record(
      test_name: "#{self.class.name}##{name}",
      template: template,
      expected: og_result,
      environment: assigns,
      filesystem: filesystem,
    )

    assert_equal og_result, il_result,
      "#{msg || "Output mismatch"}\n  Template: #{template.inspect}\n" \
      "  Assigns: #{assigns.inspect}\n  OG Liquid: #{og_result.inspect}\n  LiquidIL: #{il_result.inspect}"
  end

  private

  def extract_filesystem_hash(fs)
    return {} if fs.nil?
    return fs if fs.is_a?(Hash)
    fs.instance_variable_defined?(:@templates) ? fs.instance_variable_get(:@templates) : {}
  end
end
