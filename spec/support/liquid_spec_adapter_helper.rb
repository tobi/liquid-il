# frozen_string_literal: true

module LiquidSpecAdapterHelper
  extend self

  BASIC_MISSING_FEATURES = [
    :ruby_types,
    :lax_parsing,
    :shopify_tags,
    :shopify_objects,
    :shopify_filters,
    :shopify_error_handling,
    :shopify_blank,
    :shopify_string_access,
    :shopify_error_format,
    :shopify_includes,
    :ruby_drops,
    :drop_class_output,
    :template_factory,
    :binary_data,
    :activesupport,
  ].freeze

  SHOPIFY_MISSING_FEATURES = [
    :ruby_types,
    :lax_parsing,
    :shopify_error_handling,
    :shopify_blank,
    :shopify_string_access,
    :shopify_error_format,
    :shopify_includes,
    :ruby_drops,
    :drop_class_output,
    :template_factory,
    :binary_data,
    :activesupport,
  ].freeze

  def known_failures
    File.readlines(File.expand_path("../known_failures.txt", __dir__), chomp: true).filter_map do |line|
      line = line.strip
      line unless line.empty? || line.start_with?("#")
    end
  end

  def context_options(compile_options)
    {
      file_system: compile_options[:file_system],
      registers: compile_options[:registers],
      strict_errors: compile_options[:strict_errors],
      resource_limits: compile_options[:resource_limits],
      error_mode: compile_options[:error_mode] || :strict,
    }
  end

  def render_options(render_options)
    {
      render_errors: !render_options.fetch(:strict_errors, false),
      registers: render_options[:registers] || {},
    }
  end

  def with_frozen_time(&block)
    original_tz = ENV["TZ"]
    ENV["TZ"] = "UTC"

    Liquid::Spec::TimeFreezer.freeze(Liquid::Spec::AdapterRunner::TEST_TIME, &block)
  ensure
    ENV["TZ"] = original_tz
  end
end
