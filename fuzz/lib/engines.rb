# frozen_string_literal: true

require "timeout"
require_relative "envelope"

module Fuzz
  # Minimal in-memory filesystem shared by both engines' render paths.
  # Mirrors liquid-spec's SimpleFileSystem (grep `raw_filesystem` /
  # `instantiate_filesystem` in the liquid-spec checkout's lib/): a plain
  # name => source Hash, with a `.liquid` suffix fallback.
  class MemoryFileSystem
    def initialize(files) = @files = files || {}

    def read_template_file(name, _context = nil)
      @files[name] || @files["#{name}.liquid"] ||
        (raise Liquid::FileSystemError, "No such template '#{name}'" if defined?(Liquid::FileSystemError))
    end
  end

  class HangError < StandardError; end

  # Renders one Case through reference `liquid`, in-process (goal 02 doc,
  # "hardest part #1"). Never touches the deprecated Liquid::Template.
  # file_system= / Environment.default global -- file_system is passed
  # per-call via Context.build(registers: ...), so there is no cross-case
  # global state to reset. #assert_pristine! is a defensive check that
  # nothing else touched the global on our behalf.
  module ReferenceEngine
    def self.assert_pristine!
      return unless defined?(Liquid::Environment)

      fs = Liquid::Environment.default.file_system
      return if fs.is_a?(Liquid::BlankFileSystem)

      raise "Liquid::Environment.default.file_system was mutated by a case " \
            "(now #{fs.class}) -- reference global state leaked across cases"
    end

    def self.render(kase, timeout: 2)
      Timeout.timeout(timeout, HangError) do
        registers = {}
        registers[:file_system] = MemoryFileSystem.new(kase.filesystem) if kase.filesystem && !kase.filesystem.empty?
        template = Liquid::Template.parse(kase.template_src, error_mode: kase.error_mode)
        context = Liquid::Context.build(static_environments: kase.environment, registers: registers)
        output = template.render(context)
        { ok: true, output: output }
      end
    rescue HangError
      { ok: false, hang: true }
    rescue Liquid::SyntaxError => e
      { ok: false, syntax_error: true, error_class: e.class.name, message: e.message }
    rescue StandardError, ScriptError => e
      # ScriptError (SyntaxError from RubyVM::InstructionSequence.compile on
      # generated Ruby, LoadError, ...) is deliberately included: a codegen
      # bug that emits unparsable Ruby is itself a real finding, not
      # something that should crash the fuzzer.
      { ok: false, error_class: e.class.name, message: e.message }
    ensure
      assert_pristine!
    end
  end

  # Renders one Case through LiquidIL, in-process. Mirrors spec/liquid_il.rb
  # (the liquid-spec adapter): environment values ride as static_environments,
  # not assigns/locals, matching reference's Context.build(static_environments:).
  module LiquidILEngine
    def self.render(kase, timeout: 2)
      Timeout.timeout(timeout, HangError) do
        fs = kase.filesystem && !kase.filesystem.empty? ? MemoryFileSystem.new(kase.filesystem) : nil
        context = LiquidIL::Context.new(file_system: fs, error_mode: kase.error_mode)
        template = context.parse(kase.template_src)
        output = template.render({}, static_environments: kase.environment, render_errors: true)
        { ok: true, output: output, template: template }
      end
    rescue HangError
      { ok: false, hang: true }
    rescue LiquidIL::SyntaxError => e
      { ok: false, syntax_error: true, error_class: e.class.name, message: e.message }
    rescue StandardError, ScriptError => e
      # See ReferenceEngine.render: a codegen bug that emits a Ruby
      # SyntaxError (ScriptError, not StandardError) is itself a finding.
      { ok: false, error_class: e.class.name, message: e.message }
    end

    # Self-consistency oracle (goal 02 doc, "Runner mechanics"): serialize
    # the just-rendered template to the compiled-artifact format, reload it,
    # and render again with the same environment. Any difference is a
    # LiquidIL artifact/codegen bug independent of reference liquid -- free
    # extra coverage `rake bench:cold` only gets for 12 fixed templates.
    def self.render_via_artifact(template, kase, timeout: 2)
      Timeout.timeout(timeout, HangError) do
        blob = template.to_artifact
        loaded = LiquidIL::Artifact.load(blob)
        # The loaded artifact carries no context, so its file_system must be
        # threaded in via registers (Template.render / CompiledArtifact.render
        # both read registers[:file_system]). Without this, every {% render %} /
        # {% include %} -- including the missing-partial and syntax-error-partial
        # error paths -- collapses to "This liquid context does not allow
        # includes.", diverging from the direct render for the identical
        # (template, environment, filesystem). Mirror the direct-render side,
        # which builds the same MemoryFileSystem in LiquidILEngine.render.
        registers = {}
        if kase.filesystem && !kase.filesystem.empty?
          registers[:file_system] = MemoryFileSystem.new(kase.filesystem)
        end
        output = loaded.render({}, static_environments: kase.environment,
                               render_errors: true, registers: registers)
        { ok: true, output: output }
      end
    rescue HangError
      { ok: false, hang: true }
    rescue StandardError, ScriptError => e
      { ok: false, error_class: e.class.name, message: e.message }
    end
  end
end
