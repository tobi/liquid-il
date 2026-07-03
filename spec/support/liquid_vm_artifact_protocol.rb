# frozen_string_literal: true

# Adds liquid-spec's compiled-artifact protocol to Shopify/liquid-vm adapters.
# The private adapters compile to Liquid::Vm::CompiledTemplate objects, which
# expose #serialize and .deserialize for bytecode. This wrapper keeps the
# private adapter's compile/render behavior and layers dump/load on top.
module LiquidVmArtifactProtocol
  module_function

  FORMAT_VERSION = 1

  def install!(backend:)
    original_compile = LiquidSpec.compile_block
    raise "liquid-vm adapter must define compile before installing artifact protocol" unless original_compile

    LiquidSpec.compile do |ctx, source, compile_options|
      original_compile.call(ctx, source, compile_options)
      ctx[:artifact_error_mode] = (compile_options[:error_mode] || :strict).to_s
      # Capture bytecode immediately after compile. liquid-vm mutates some
      # bytecode-embedded runtime state (notably cycle indexes) during render,
      # while liquid-spec verifies output before asking the adapter to dump an
      # artifact. Dumping this pristine snapshot models compile-once -> persist.
      ctx[:artifact_template_bytes] = ctx[:template].serialize
      ctx[:artifact_template_name] = ctx[:template].respond_to?(:name) ? ctx[:template].name : nil
      ctx[:artifact_partials] = serialize_partials(backend, compile_options)
    end

    LiquidSpec.dump_artifact do |ctx|
      Marshal.dump(
        "version" => FORMAT_VERSION,
        "template" => ctx.fetch(:artifact_template_bytes),
        "name" => ctx[:artifact_template_name],
        "error_mode" => ctx[:artifact_error_mode] || "strict",
        "partials" => ctx[:artifact_partials] || {},
      )
    end

    LiquidSpec.load_artifact do |ctx, blob, _load_options|
      data = Marshal.load(blob)
      unless data.is_a?(Hash) && data["version"] == FORMAT_VERSION
        raise "unsupported liquid-vm artifact format"
      end

      ctx[:template] = deserialize_template(data.fetch("template"), data["name"])
      ctx[:artifact_error_mode] = data["error_mode"] || "strict"
      ctx[:artifact_partials] = data["partials"] || {}
      ctx[:cached_partials] = build_cached_partials(ctx[:artifact_partials], ctx[:artifact_error_mode])
    end
  end

  def serialize_partials(backend, compile_options)
    file_system = compile_options[:file_system]
    return {} unless file_system&.respond_to?(:data)

    opts = parse_options(compile_options)
    error_mode = compile_options[:error_mode] || :strict
    compiler = Liquid::Vm::Compiler.new
    partials = {}

    file_system.data.each_key do |partial_name|
      source = file_system.read_template_file(partial_name)
      partial_template = Liquid::Template.parse(source, **opts.merge(error_mode: error_mode))
      partial_template.name ||= partial_name
      compiled_partial = compile_template(compiler, partial_template, backend, top_level: false)
      partials[partial_name] = compiled_partial.serialize
    rescue StandardError
      # Match the private adapter: partials that cannot be precompiled are
      # resolved by liquid-vm's runtime partial retriever on first render.
    end

    partials
  end

  def parse_options(compile_options)
    allowed_keys = [:line_numbers, :error_mode, :disable_liquid_c_nodes]
    opts = compile_options.slice(*allowed_keys)
    if defined?(Helpers::LiquidHelper::DEFAULT_OPTIONS)
      Helpers::LiquidHelper::DEFAULT_OPTIONS.merge(opts)
    else
      opts
    end
  end

  def compile_template(compiler, template, backend, top_level:)
    if backend.to_sym == :ssa
      compiler.compile_template(template, optimised: true, top_level: top_level)
    else
      compiler.compile_template(template)
    end
  end

  def deserialize_template(bytes, name = nil)
    template = Liquid::Vm::CompiledTemplate.deserialize(bytes)
    template.name = name if name && template.respond_to?(:name=)
    template
  end

  def build_cached_partials(serialized_partials, error_mode)
    return nil if serialized_partials.empty?

    store = Liquid::Vm::CachedPartialsStore.new
    serialized_partials.each do |name, bytes|
      partial = deserialize_template(bytes, name)
      store.preload(name, 0, error_mode.to_s, Liquid::Vm::CachedPartial.new(partial, nil))
    end
    store
  end
end
