# frozen_string_literal: true

require_relative "render"

module Fuzz
  # A single generated (template, environment) pair plus everything needed
  # to reproduce and re-render it. `ast` is the generator's statement-list
  # AST (array of Hash nodes, see gen.rb) -- keeping it around (not just the
  # rendered source) is what makes AST-level structural shrinking possible.
  class Case
    attr_reader :seed, :ast, :environment, :filesystem, :error_mode

    # `template_src:` lets a caller supply literal template text directly
    # (calibrate.rb replaying real liquid-spec fixtures, ref_check.rb
    # replaying one already-generated case) without needing a matching AST
    # -- the AST is only required when the shrinker needs to mutate it.
    def initialize(seed:, ast:, environment:, filesystem: {}, error_mode: :strict, template_src: nil)
      @seed = seed
      @ast = ast
      @environment = environment
      @filesystem = filesystem
      @error_mode = error_mode
      @template_src = template_src
    end

    def template_src
      @template_src ||= Render.block_to_source(ast)
    end

    def filesystem_src
      filesystem
    end

    def with(ast: @ast, environment: @environment, filesystem: @filesystem, error_mode: @error_mode)
      Case.new(seed: seed, ast: ast, environment: environment, filesystem: filesystem, error_mode: error_mode)
    end

    def self.literal(seed:, template_src:, environment: {}, filesystem: {}, error_mode: :strict)
      new(seed: seed, ast: [], environment: environment, filesystem: filesystem,
        error_mode: error_mode, template_src: template_src)
    end

    def to_h
      {
        seed: seed,
        template: template_src,
        environment: environment,
        filesystem: filesystem,
        error_mode: error_mode,
      }
    end
  end
end
