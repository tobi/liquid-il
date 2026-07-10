# frozen_string_literal: true

# Adds liquid-spec's compiled-artifact protocol to Shopify/liquid-vm adapters.
# The private adapters compile to Liquid::Vm::CompiledTemplate objects, which
# expose #serialize and .deserialize for bytecode. This wrapper keeps the
# private adapter's compile/render behavior and layers dump/load on top.
module LiquidVmArtifactProtocol
  module_function

  FORMAT_VERSION = 2

  def install!(backend:)
    original_compile = LiquidSpec.compile_block
    original_render = LiquidSpec.render_block
    raise "liquid-vm adapter must define compile before installing artifact protocol" unless original_compile
    raise "liquid-vm adapter must define render before installing artifact protocol" unless original_render

    # The private adapter passes the caller's register Hash directly to
    # Liquid::Registers. VM render state (including cycle counters) can then
    # leak into the next benchmark render. Give every render its own register
    # container, matching Liquid's per-render Context semantics without
    # cloning the potentially large assigns tree.
    LiquidSpec.render do |ctx, assigns, render_options|
      options = render_options.dup
      options[:registers] = render_options[:registers].dup if render_options[:registers]
      original_render.call(ctx, assigns, options)
    end

    LiquidSpec.compile do |ctx, source, compile_options|
      original_compile.call(ctx, source, compile_options)
      ctx[:artifact_error_mode] = (compile_options[:error_mode] || :strict).to_s
      ctx[:artifact_compile_options] = compile_options
    end

    LiquidSpec.dump_artifact do |ctx|
      template = ctx.fetch(:template)
      # Serialization belongs exclusively to the dump hook. Doing it in the
      # compile hook would charge liquid-vm's source workflow for artifact work
      # that the other adapters do not perform and make timings incomparable.
      # Persist the exact partial bytecode produced by the adapter's normal
      # shared compiler; independently recompiling it changes VM identities.
      partials = serialize_partials(ctx, ctx.fetch(:artifact_compile_options))
      Marshal.dump(
        "version" => FORMAT_VERSION,
        "template" => template.serialize,
        "name" => template.respond_to?(:name) ? template.name : nil,
        "error_mode" => ctx[:artifact_error_mode] || "strict",
        "partials" => partials,
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

  def serialize_partials(ctx, compile_options)
    file_system = compile_options[:file_system]
    store = ctx[:cached_partials]
    return {} unless store && file_system&.respond_to?(:data)

    error_mode = (compile_options[:error_mode] || :strict).to_s
    partials = {}

    file_system.data.each_key do |partial_name|
      cached = store.fetch(partial_name, 0, error_mode)
      next unless cached
      next if cached.custom_renderer

      template = cached.compiled_template
      partials[partial_name] = {
        "template" => template.serialize,
        "name" => template.respond_to?(:name) ? template.name : partial_name,
      }
    end

    partials
  end

  def deserialize_template(bytes, name = nil)
    template = Liquid::Vm::CompiledTemplate.deserialize(bytes)
    template.name = name if name && template.respond_to?(:name=)
    template
  end

  def build_cached_partials(serialized_partials, error_mode)
    return nil if serialized_partials.empty?

    store = Liquid::Vm::CachedPartialsStore.new
    serialized_partials.each do |name, entry|
      partial = deserialize_template(entry.fetch("template"), entry["name"] || name)
      store.preload(name, 0, error_mode.to_s, Liquid::Vm::CachedPartial.new(partial, nil))
    end
    store
  end
end
