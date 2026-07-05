# frozen_string_literal: true

require_relative "case"
require_relative "render"

module Fuzz
  # Tracks which variable names are in scope while generating a template
  # body, so generated `{{ var }}` / `self[...]` references are usually
  # "real" (bind to something) rather than always-undefined. Also tracks
  # loop nesting depth: `self[...]` inside 2+ nested loops is exactly the
  # shape of the historical bug this fuzzer exists to rediscover (goal 02
  # doc), so the expression generator biases toward it as loop_depth grows.
  class Scope
    attr_reader :loop_depth, :loop_vars

    def initialize(names = [])
      @stack = [names.dup]
      @loop_depth = 0
      @loop_vars = []
      @in_loop = [false]
    end

    def names = @stack.last

    def add(name) = @stack.last << name

    def in_loop? = @in_loop.last

    def push_block(extra_names = [])
      @stack.push((@stack.last + extra_names).uniq)
      @in_loop.push(@in_loop.last)
    end

    def push_loop(var_name)
      @stack.push((@stack.last + [var_name, "forloop"]).uniq)
      @in_loop.push(true)
      @loop_depth += 1
      @loop_vars.push(var_name)
    end

    def pop
      @stack.pop
      @in_loop.pop
      if @loop_depth.positive? && @loop_vars.any?
        @loop_depth -= 1
        @loop_vars.pop
      end
    end
  end

  # A shared, mutable node-count budget threaded through the whole recursive
  # descent (not just the top-level block) so total template size stays
  # bounded regardless of nesting shape -- otherwise a budget re-rolled at
  # every nesting level compounds geometrically (observed: 40KB+ templates
  # from a "50-2000 char" target before this was shared).
  class Budget
    def initialize(cap, parent: nil)
      @cap = cap
      @parent = parent
    end

    def take!
      return false if @cap <= 0
      return false if @parent && !@parent.take!

      @cap -= 1
      true
    end

    # A nested block gets its own small local cap AND still draws from the
    # shared root counter (via the parent chain) -- bounds both "this one
    # branch can't hog everything" and "total template size stays capped"
    # at once.
    def child(cap) = Budget.new(cap, parent: self)
  end

  # Grammar-based, seeded template + environment generator (goal 02 doc,
  # "Generator design"). Produces a `Case` (AST + rendered source +
  # environment + filesystem), never free-form bytes -- every construct is
  # one both engines are expected to parse.
  class Gen
    VAR_NAMES = %w[a b c x y z item value items data list values entry record
                   user product info total count flag config nums names].freeze
    LOOP_VAR_NAMES = %w[item value entry row elem node it].freeze
    PARTIAL_NAMES = %w[header footer item_partial card row nested aside].freeze
    DOT_SEGMENTS = %w[name id price size title value first last count url].freeze
    ARG_NAMES = %w[title flag n key label].freeze
    AS_NAMES = %w[item it x thing].freeze

    STRING_SAMPLES = [
      "hello", "Hello, World!", "", " ", "42", "true", "false", "nil",
      "{{ not_a_tag }}", "{% not_a_tag %}", "PRICE_START_99_END", "_S_marker_",
      "café", "日本語こんにちは", "emoji \u{1F600}",
      "quote\"inside", "line1\nline2", "  padded  ", "a,b,c,d",
    ].freeze

    RAW_TEXT_SAMPLES = [
      "Hello, World!\n", "  ", "\n", "price: $9.99\n", "50% off\n",
      "a { brace } c\n", "<div>markup</div>\n", "tab\there\n",
      "café 日本語\n", "emoji \u{1F600}\n", "stray % percent\n",
      "stray { brace\n",
    ].freeze

    FILTERS_UNARY = %w[upcase downcase capitalize strip lstrip rstrip
                        strip_newlines escape escape_once url_encode url_decode
                        size first last reverse sort sort_natural uniq compact
                        abs ceil floor round json].freeze
    FILTERS_ARG = %w[append prepend truncate truncatewords split join slice
                      replace remove plus minus times divided_by modulo
                      default at_least at_most].freeze
    FILTER_ARGC = { "replace" => 2, "replace_first" => 2, "slice" => 2,
                     "truncate" => 2, "truncatewords" => 2 }.freeze
    FORLOOP_FIELDS = %w[index index0 rindex rindex0 first last length].freeze
    COMPARISON_OPS = ["==", "!=", ">", "<", ">=", "<=", "contains"].freeze

    NEST_MAX = 4

    attr_reader :random, :seed

    def initialize(seed = nil)
      @seed = seed || Random.new_seed
      @random = Random.new(@seed)
    end

    # Generates one full Case: template AST, environment, filesystem.
    def generate
      target_size = random.rand(50..2000)
      node_cap = [[(target_size / 45.0).ceil, 3].max, 45].min
      filesystem = gen_filesystem
      scope = Scope.new(gen_environment_names)
      environment = gen_environment(scope.names)
      ast = nil
      8.times do
        ast = gen_block(scope, depth: 0, budget: Budget.new(node_cap), partials: filesystem.keys)
        src = Render.block_to_source(ast)
        break if src.bytesize <= 4000
      end
      Case.new(seed: seed, ast: ast, environment: environment, filesystem: filesystem, error_mode: :strict)
    end

    # --- environment / value pool ---------------------------------------

    def gen_environment_names
      VAR_NAMES.sample(random.rand(1..6), random: random)
    end

    def gen_environment(names)
      names.each_with_object({}) { |name, h| h[name] = gen_value }
    end

    def gen_value(depth = 0)
      bucket = depth >= 3 ? 0 : random.rand(5)
      case bucket
      when 3 then gen_array(depth + 1)
      when 4 then gen_hash(depth + 1)
      else gen_scalar
      end
    end

    def gen_scalar
      case random.rand(6)
      when 0 then gen_string
      when 1 then [0, 1, -1, 2**62, -(2**62), random.rand(-1000..1000)].sample(random: random)
      when 2 then [0.0, -0.5, 1.5, 3.14159].sample(random: random) || random.rand * 1000
      when 3 then nil
      when 4 then true
      else false
      end
    end

    def gen_string
      base = STRING_SAMPLES.sample(random: random)
      random.rand(4).zero? ? "#{base}#{random.rand(1000)}" : base
    end

    def gen_array(depth)
      n = depth <= 1 ? random.rand(0..5) : random.rand(0..3)
      Array.new(n) { gen_value(depth) }
    end

    def gen_hash(depth)
      n = depth <= 1 ? random.rand(0..5) : random.rand(0..3)
      keys = Array.new(n) { gen_key }.uniq
      keys.each_with_object({}) { |k, h| h[k] = gen_value(depth) }
    end

    # Only String keys -- see fuzz/lib/envelope.rb: JSON round-tripping
    # (required for subprocess confirmation) precludes literal Integer/Symbol
    # Hash keys, so "hash with integer keys" is represented as digit-string
    # keys instead (still exercises bracket lookup by an integer-looking key).
    def gen_key
      ["name", "id", "3", "0", "product_name", "PRICE_START", "a", "b", "key_#{random.rand(100)}"].sample(random: random)
    end

    def gen_filesystem
      return {} if random.rand(3).zero?

      n = random.rand(1..3)
      names = PARTIAL_NAMES.sample(n, random: random).uniq
      scope = Scope.new
      names.each_with_object({}) do |name, fs|
        body = gen_block(scope, depth: 1, budget: Budget.new(6), partials: [])
        fs[name] = Render.block_to_source(body)
      end
    end

    # --- template AST ----------------------------------------------------

    def gen_block(scope, depth:, budget:, partials:)
      stmts = []
      stmts << gen_stmt(scope, depth, budget, partials) while budget.take!
      stmts
    end

    LEAF_WEIGHTS = { raw: 8, output: 10, assign: 3, echo: 2, increment: 1, decrement: 1, cycle: 2 }.freeze
    CONTROL_WEIGHTS = { if: 6, unless: 2, case: 2, for: 6, capture: 2, tablerow: 1,
                         comment: 1, raw_tag: 1, render: 2, include: 2, liquid_block: 1 }.freeze

    def gen_stmt(scope, depth, budget, partials)
      pool = LEAF_WEIGHTS.dup
      pool.merge!(CONTROL_WEIGHTS) if depth < NEST_MAX
      pool[:break] = 1 if scope.in_loop?
      pool[:continue] = 1 if scope.in_loop?
      pool.delete(:render) if partials.empty?
      pool.delete(:include) if partials.empty?
      type = weighted_choice(pool)
      send(:"gen_#{type}", scope, depth, budget, partials)
    end

    def child_budget(budget, max = 3) = budget.child(random.rand(1..max))

    def weighted_choice(weights)
      total = weights.values.sum
      r = random.rand(total)
      acc = 0
      weights.each do |k, w|
        acc += w
        return k if r < acc
      end
      weights.keys.last
    end

    def gen_raw(_scope, _depth, _budget, _partials) = { type: :raw, text: RAW_TEXT_SAMPLES.sample(random: random) }

    def gen_output(scope, _depth, _budget, _partials)
      { type: :output, expr: gen_expr(scope), ws: random.rand(6).zero? }
    end

    def gen_echo(scope, _depth, _budget, _partials)
      { type: :echo, expr: gen_expr(scope), ws: random.rand(8).zero? }
    end

    def gen_assign(scope, _depth, _budget, _partials)
      name = pick_name(scope)
      node = { type: :assign, name: name, expr: gen_expr(scope), ws: random.rand(8).zero? }
      scope.add(name)
      node
    end

    def pick_name(scope)
      random.rand(2).zero? && !scope.names.empty? ? scope.names.sample(random: random) : VAR_NAMES.sample(random: random)
    end

    def gen_increment(_scope, _depth, _budget, _partials) = { type: :increment, name: VAR_NAMES.sample(random: random) }
    def gen_decrement(_scope, _depth, _budget, _partials) = { type: :decrement, name: VAR_NAMES.sample(random: random) }

    def gen_cycle(scope, _depth, _budget, _partials)
      n = random.rand(1..4)
      values = Array.new(n) { gen_leaf_expr(scope) }
      name = random.rand(2).zero? ? nil : VAR_NAMES.sample(random: random)
      { type: :cycle, name: name, values: values }
    end

    def gen_comment(_scope, _depth, _budget, _partials) = { type: :comment, text: RAW_TEXT_SAMPLES.sample(random: random) }
    def gen_raw_tag(_scope, _depth, _budget, _partials) = { type: :raw_tag, text: RAW_TEXT_SAMPLES.sample(random: random) }

    def gen_capture(scope, depth, budget, partials)
      name = pick_name(scope)
      scope.push_block
      body = gen_block(scope, depth: depth + 1, budget: child_budget(budget), partials: partials)
      scope.pop
      scope.add(name)
      { type: :capture, name: name, body: body }
    end

    def gen_if(scope, depth, budget, partials) = gen_if_like(scope, depth, budget, partials, :if)
    def gen_unless(scope, depth, budget, partials) = gen_if_like(scope, depth, budget, partials, :unless)

    def gen_if_like(scope, depth, budget, partials, keyword)
      n = random.rand(1..3)
      branches = Array.new(n) do
        scope.push_block
        body = gen_block(scope, depth: depth + 1, budget: child_budget(budget), partials: partials)
        scope.pop
        { cond: gen_cond(scope), body: body }
      end
      else_body = nil
      if random.rand(2).zero?
        scope.push_block
        else_body = gen_block(scope, depth: depth + 1, budget: child_budget(budget), partials: partials)
        scope.pop
      end
      { type: keyword, branches: branches, else_body: else_body, ws: random.rand(10).zero? }
    end

    def gen_case(scope, depth, budget, partials)
      n = random.rand(1..3)
      # `case`'s subject is QuotedFragment-parsed too (see Liquid::Case
      # Syntax/WhenSyntax) -- no filters allowed, same as gen_cond.
      subject = gen_leaf_expr(scope)
      whens = Array.new(n) do
        scope.push_block
        body = gen_block(scope, depth: depth + 1, budget: child_budget(budget), partials: partials)
        scope.pop
        vn = random.rand(1..2)
        { values: Array.new(vn) { gen_leaf_expr(scope) }, body: body }
      end
      else_body = nil
      if random.rand(2).zero?
        scope.push_block
        else_body = gen_block(scope, depth: depth + 1, budget: child_budget(budget), partials: partials)
        scope.pop
      end
      { type: :case, expr: subject, whens: whens, else_body: else_body }
    end

    def gen_for(scope, depth, budget, partials)
      var = LOOP_VAR_NAMES.sample(random: random)
      coll = gen_collection_expr(scope, scope.loop_depth)
      scope.push_loop(var)
      body = gen_block(scope, depth: depth + 1, budget: child_budget(budget), partials: partials)
      scope.pop
      else_body = nil
      if random.rand(3).zero?
        scope.push_block
        else_body = gen_block(scope, depth: depth + 1, budget: child_budget(budget, 2), partials: partials)
        scope.pop
      end
      node = { type: :for, var: var, coll: coll, body: body, else_body: else_body,
                reversed: random.rand(4).zero?, ws: random.rand(10).zero? }
      if random.rand(2).zero?
        node[:limit] = { type: :lit, value: random.rand(0..8) }
      end
      if random.rand(3).zero?
        if random.rand(2).zero?
          node[:offset_continue] = true
        else
          node[:offset] = { type: :lit, value: random.rand(0..8) }
        end
      end
      node
    end

    def gen_break(_scope, _depth, _budget, _partials) = { type: :break }
    def gen_continue(_scope, _depth, _budget, _partials) = { type: :continue }

    def gen_tablerow(scope, depth, budget, partials)
      var = LOOP_VAR_NAMES.sample(random: random)
      coll = gen_collection_expr(scope, scope.loop_depth)
      scope.push_loop(var)
      body = gen_block(scope, depth: depth + 1, budget: child_budget(budget), partials: partials)
      scope.pop
      node = { type: :tablerow, var: var, coll: coll, body: body }
      node[:cols] = { type: :lit, value: random.rand(1..4) } if random.rand(2).zero?
      node[:limit] = { type: :lit, value: random.rand(0..6) } if random.rand(3).zero?
      node[:offset] = { type: :lit, value: random.rand(0..6) } if random.rand(3).zero?
      node
    end

    def gen_render(scope, _depth, _budget, partials) = gen_render_like(scope, partials, :render)
    def gen_include(scope, _depth, _budget, partials) = gen_render_like(scope, partials, :include)

    def gen_render_like(scope, partials, type)
      name = partials.sample(random: random)
      mode = [:none, :with, :for].sample(random: random)
      target_expr = nil
      as_name = nil
      if mode == :with
        target_expr = gen_leaf_expr(scope)
        as_name = AS_NAMES.sample(random: random) if random.rand(2).zero?
      elsif mode == :for
        target_expr = scope.names.empty? ? gen_leaf_expr(scope) : gen_var_chain(scope)
        as_name = AS_NAMES.sample(random: random) if random.rand(2).zero?
      end
      argc = random.rand(0..2)
      args = argc.times.each_with_object({}) { |_, h| h[ARG_NAMES.sample(random: random)] = gen_leaf_expr(scope) }
      { type: type, name: name, mode: mode, target_expr: target_expr, as_name: as_name, args: args }
    end

    def gen_liquid_block(scope, _depth, _budget, _partials)
      n = random.rand(1..3)
      lines = Array.new(n) do
        if random.rand(2).zero?
          name = pick_name(scope)
          scope.add(name)
          { type: :assign, name: name, expr: gen_expr(scope) }
        else
          { type: :echo, expr: gen_expr(scope) }
        end
      end
      { type: :liquid_block, lines: lines }
    end

    # --- expressions -------------------------------------------------------

    # General-purpose expression: usable in {{ }}, assign, filter args,
    # case/when values, cycle/render args. Deliberately excludes bare
    # comparisons/logicals and array/hash/range literals -- Liquid has no
    # literal syntax for those; comparisons are only valid in cond position
    # (see gen_cond) and ranges only in for/tablerow collections.
    def gen_expr(scope, depth = 0)
      return gen_leaf_expr(scope) if depth >= 3

      r = random.rand(100)
      if r < 45
        gen_leaf_expr(scope)
      else
        gen_filter_chain(scope, depth)
      end
    end

    def gen_leaf_expr(scope)
      r = random.rand(100)
      if scope.in_loop? && r < 12
        gen_forloop_chain(scope)
      elsif scope.loop_depth >= 2 && r < 35
        gen_self_index(scope)
      elsif r < 70 && !scope.names.empty?
        gen_var_chain(scope)
      else
        { type: :lit, value: gen_scalar }
      end
    end

    def gen_var_chain(scope)
      base = random.rand(100) < 85 && !scope.names.empty? ? scope.names.sample(random: random) : VAR_NAMES.sample(random: random)
      n = random.rand(0..2)
      accessors = Array.new(n) do
        random.rand(2).zero? ? { dot: DOT_SEGMENTS.sample(random: random) } : { bracket: gen_expr(scope, 3) }
      end
      { type: :chain, base: base, accessors: accessors }
    end

    # The historical bug class this fuzzer targets: `self[...]` referencing
    # a loop variable while nested inside 2+ loops (see liquid-spec
    # self_sees_loop_variables_across_three_nested_loops).
    def gen_self_index(scope)
      key = if scope.loop_vars.any? && random.rand(2).zero?
        { type: :chain, base: scope.loop_vars.sample(random: random), accessors: [] }
      else
        gen_expr(scope, 3)
      end
      { type: :chain, base: :self, accessors: [{ bracket: key }] }
    end

    def gen_forloop_chain(scope)
      hops = scope.loop_depth > 1 ? random.rand(0...scope.loop_depth) : 0
      accessors = Array.new(hops) { { dot: "parentloop" } }
      accessors << { dot: FORLOOP_FIELDS.sample(random: random) }
      { type: :chain, base: "forloop", accessors: accessors }
    end

    def gen_filter_chain(scope, _depth)
      target = gen_leaf_expr(scope)
      random.rand(1..3).times do
        if random.rand(2).zero?
          name = FILTERS_UNARY.sample(random: random)
          target = { type: :filter, target: target, name: name, args: [] }
        else
          name = FILTERS_ARG.sample(random: random)
          argc = FILTER_ARGC[name] || 1
          # Filter arguments are parsed with the bare expression grammar
          # (Liquid::Variable#parse_filterargs -> safe_parse_expression) --
          # a nested pipe here is a reference syntax error, so args must be
          # leaf expressions, never another filter chain.
          args = Array.new(argc) { gen_leaf_expr(scope) }
          target = { type: :filter, target: target, name: name, args: args }
        end
      end
      target
    end

    # Condition expression: if/unless branch conditions only. Reference
    # Liquid's Condition#parse_expression parses left/right operands with
    # the bare expression grammar (Liquid::Condition, ParseContext#
    # parse_expression) -- filters are a `{{ }}`/`assign`-only construct
    # (Liquid::Variable wraps expression + filters; Condition does not), so
    # `{% if x | upcase == y %}` is a reference syntax error. Operands here
    # must stay filter-free (gen_leaf_expr), never gen_expr/gen_filter_chain.
    def gen_cond(scope, depth = 0)
      return gen_leaf_expr(scope) if depth >= 2

      case random.rand(4)
      when 0 then { type: :binop, op: COMPARISON_OPS.sample(random: random), left: gen_leaf_expr(scope), right: gen_leaf_expr(scope) }
      when 1 then { type: :logical, op: %w[and or].sample(random: random), left: gen_cond(scope, depth + 1), right: gen_cond(scope, depth + 1) }
      when 2 then { type: :binop, op: "contains", left: gen_leaf_expr(scope), right: gen_leaf_expr(scope) }
      else gen_leaf_expr(scope)
      end
    end

    # Only used for `for`/`tablerow` collections. Reference Liquid's `for`
    # tag parses its collection with a plain QuotedFragment regex (see
    # Shopify/liquid lib/liquid/tags/for.rb `Syntax`) -- NOT the full
    # expression/filter grammar -- so `for x in y | filter` is a syntax
    # error in reference liquid even though it's a valid `{{ }}` expression.
    # (LiquidIL accepting it anyway was the fuzzer's first real find --
    # see fuzz/findings/for_loop_collection_accepts_filter_pipe.yml.)
    # A bounded collection is therefore either a range literal or a
    # reference to a real (possibly array-valued) scope variable; `cap`
    # shrinks with nesting depth so nested loops can't multiply into a hang
    # (belt-and-braces on top of the per-case render timeout).
    def gen_collection_expr(scope, loop_depth)
      cap = loop_depth <= 0 ? 12 : (loop_depth == 1 ? 6 : 4)
      if random.rand(2).zero? || scope.names.empty?
        lo = random.rand(0..cap)
        hi = lo + random.rand(0..cap)
        { type: :range, from: { type: :lit, value: lo }, to: { type: :lit, value: hi } }
      else
        gen_var_chain(scope)
      end
    end
  end
end
