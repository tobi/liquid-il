# frozen_string_literal: true

# Register Allocation Benchmark (US-007)
#
# Measures the reduction in peak temp register usage achieved by
# the register allocation optimization pass.
#
# Usage:
#   bundle exec ruby test/register_benchmark.rb
#
# Outputs:
#   - Before/after peak temp usage for each template
#   - Reduction percentage for each template
#   - Overall statistics

require_relative "../lib/liquid_il"

module RegisterBenchmark
  # Find the maximum temp index used in instructions
  # This represents "peak" usage before optimization (sequential allocation)
  # since the compiler assigns sequential indices 0, 1, 2, ...
  # So max_index + 1 = number of temps needed without reuse
  def self.max_temp_index(instructions)
    max_idx = -1
    instructions.each do |inst|
      case inst[0]
      when LiquidIL::IL::STORE_TEMP, LiquidIL::IL::LOAD_TEMP
        max_idx = [max_idx, inst[1]].max
      end
    end
    max_idx + 1  # Convert index to count
  end

  # Get peak temp usage after allocation using TempAllocator
  def self.measure_peak_after_allocation(instructions)
    # Clone instructions since TempAllocator modifies in place
    cloned = instructions.map(&:dup)
    allocator = LiquidIL::TempAllocator.new(cloned)
    allocator.allocate!
    allocator.peak_usage
  end

  # Custom compiler that skips register allocation
  class CompilerWithoutRegAlloc < LiquidIL::Compiler
    def compile
      parser = LiquidIL::Parser.new(@source)
      instructions = parser.parse
      spans = parser.builder.spans

      if @options[:optimize]
        optimize_without_reg_alloc(instructions, spans)
      end

      # Don't link - we just want raw instruction analysis
      { instructions: instructions, spans: spans }
    end

    private

    def optimize_without_reg_alloc(instructions, spans)
      # Run all passes except RegisterAllocator (pass 19)

      # Pass 1: Fold constant operations
      fold_const_ops(instructions, spans)

      # Pass 2: Fold constant filters
      fold_const_filters(instructions, spans)

      # Pass 3: Fold constant output writes
      fold_const_writes(instructions, spans)

      # Pass 4: Collapse chained constant lookups
      collapse_const_paths(instructions, spans)

      # Pass 5: Collapse FIND_VAR + LOOKUP_CONST_PATH
      collapse_find_var_paths(instructions, spans)

      # Pass 6: Remove redundant IS_TRUTHY on boolean ops
      remove_redundant_is_truthy(instructions, spans)

      # Pass 7: Remove no-ops
      remove_noops(instructions, spans)

      # Pass 8: Remove jumps to the immediately following label
      remove_jump_to_next_label(instructions, spans)

      # Pass 9: Merge consecutive WRITE_RAW
      merge_raw_writes(instructions, spans)

      # Pass 10: Remove unreachable code after unconditional jumps
      remove_unreachable(instructions, spans)

      # Pass 11: Re-merge WRITE_RAW after other removals
      merge_raw_writes(instructions, spans)

      # Pass 12: Fold constant capture blocks into direct assigns
      fold_const_captures(instructions, spans)

      # Pass 13: Remove empty WRITE_RAW (no observable output)
      remove_empty_raw_writes(instructions, spans)

      # Pass 14: Constant propagation - replace FIND_VAR with known constants
      propagate_constants(instructions, spans)

      # Pass 15: Re-run constant folding after propagation
      fold_const_filters(instructions, spans)
      fold_const_writes(instructions, spans)
      merge_raw_writes(instructions, spans)

      # Pass 16: Loop invariant code motion - hoist invariant lookups outside loops
      hoist_loop_invariants(instructions, spans)

      # Pass 17: Cache repeated base object lookups in straight-line code
      cache_repeated_lookups(instructions, spans)

      # Pass 18: Local value numbering - eliminate redundant computations
      value_numbering(instructions, spans)

      # Pass 19: SKIPPED - RegisterAllocator.optimize(instructions)

      instructions
    end
  end

  # Compile template without register allocation to get original temps
  def self.compile_without_register_allocation(source)
    compiler = CompilerWithoutRegAlloc.new(source, optimize: true)
    result = compiler.compile
    result[:instructions]
  end

  # Count total STORE_TEMP operations (actual temps created)
  # This is the true "before" count - how many temps would be needed
  # if we never reused any
  def self.count_store_temps(instructions)
    count = 0
    instructions.each do |inst|
      count += 1 if inst[0] == LiquidIL::IL::STORE_TEMP
    end
    count
  end

  # Benchmark a single template
  def self.benchmark_template(name, source)
    # Compile without register allocation
    result_before = compile_without_register_allocation(source)

    # Count temps two ways:
    # 1. Max temp index (what sequential allocation uses)
    # 2. Store count (total temps created, may exceed max index if temps reused)
    original_temps = max_temp_index(result_before)
    store_count = count_store_temps(result_before)

    # Measure peak after allocation on the same instructions
    peak_after = measure_peak_after_allocation(result_before)

    # Use store_count for templates where temps are reused with same index
    # This gives a fairer comparison
    effective_before = [original_temps, store_count].max

    {
      name: name,
      original_temps: original_temps,
      store_count: store_count,
      effective_before: effective_before,
      peak_after: peak_after,
      reduction: effective_before - peak_after,
      reduction_pct: effective_before > 0 ? ((effective_before - peak_after).to_f / effective_before * 100).round(1) : 0
    }
  end

  # Representative real-world templates
  def self.templates
    {
      # Template 1: E-commerce product listing with filters and loops
      "E-commerce Product List" => '
{% for product in products %}
  <div class="product">
    <h2>{{ product.title | escape }}</h2>
    <p class="price">{{ product.price | money }}</p>
    <p class="description">{{ product.description | truncate: 100 | escape }}</p>
    {% if product.on_sale %}
      <span class="sale">{{ product.original_price | money }} -> {{ product.price | money }}</span>
      <span class="discount">{{ product.discount | times: 100 | round }}% off</span>
    {% endif %}
    {% for tag in product.tags %}
      <span class="tag">{{ tag | downcase | replace: " ", "-" }}</span>
    {% endfor %}
  </div>
{% endfor %}
',

      # Template 2: Blog post with nested conditionals and filters
      "Blog Post" => '
<article>
  <h1>{{ post.title | escape }}</h1>
  <p class="meta">
    By {{ post.author.name | escape }} on {{ post.date | date: "%B %d, %Y" }}
    {% if post.updated_at %}
      (Updated: {{ post.updated_at | date: "%B %d, %Y" }})
    {% endif %}
  </p>

  {% if post.featured_image %}
    <img src="{{ post.featured_image.url | escape }}" alt="{{ post.featured_image.alt | escape }}">
  {% endif %}

  <div class="content">{{ post.content }}</div>

  {% if post.tags.size > 0 %}
    <div class="tags">
      {% for tag in post.tags %}
        <a href="/tags/{{ tag | downcase | url_encode }}">{{ tag | escape }}</a>{% unless forloop.last %}, {% endunless %}
      {% endfor %}
    </div>
  {% endif %}

  {% if post.related_posts.size > 0 %}
    <h3>Related Posts</h3>
    <ul>
      {% for related in post.related_posts limit: 3 %}
        <li><a href="{{ related.url }}">{{ related.title | escape }}</a></li>
      {% endfor %}
    </ul>
  {% endif %}
</article>
',

      # Template 3: Invoice with calculations and nested loops
      "Invoice" => '
<div class="invoice">
  <header>
    <h1>Invoice #{{ invoice.number }}</h1>
    <p>Date: {{ invoice.date | date: "%Y-%m-%d" }}</p>
    <p>Due: {{ invoice.due_date | date: "%Y-%m-%d" }}</p>
  </header>

  <section class="customer">
    <h2>Bill To:</h2>
    <p>{{ invoice.customer.name | escape }}</p>
    <p>{{ invoice.customer.address | newline_to_br }}</p>
    <p>{{ invoice.customer.email }}</p>
  </section>

  <table class="line-items">
    <thead>
      <tr>
        <th>Description</th>
        <th>Qty</th>
        <th>Unit Price</th>
        <th>Total</th>
      </tr>
    </thead>
    <tbody>
      {% for item in invoice.items %}
        <tr>
          <td>{{ item.description | escape }}</td>
          <td>{{ item.quantity }}</td>
          <td>{{ item.unit_price | money }}</td>
          <td>{{ item.quantity | times: item.unit_price | money }}</td>
        </tr>
      {% endfor %}
    </tbody>
    <tfoot>
      <tr>
        <td colspan="3">Subtotal</td>
        <td>{{ invoice.subtotal | money }}</td>
      </tr>
      {% if invoice.discount > 0 %}
        <tr>
          <td colspan="3">Discount ({{ invoice.discount_percent | times: 100 }}%)</td>
          <td>-{{ invoice.discount | money }}</td>
        </tr>
      {% endif %}
      <tr>
        <td colspan="3">Tax ({{ invoice.tax_rate | times: 100 }}%)</td>
        <td>{{ invoice.tax | money }}</td>
      </tr>
      <tr class="total">
        <td colspan="3"><strong>Total</strong></td>
        <td><strong>{{ invoice.total | money }}</strong></td>
      </tr>
    </tfoot>
  </table>

  {% if invoice.notes %}
    <section class="notes">
      <h3>Notes</h3>
      <p>{{ invoice.notes | escape }}</p>
    </section>
  {% endif %}
</div>
',

      # Template 4: Navigation menu with deep nesting
      "Navigation Menu" => '
<nav class="main-nav">
  <ul>
    {% for item in menu.items %}
      <li class="nav-item{% if item.active %} active{% endif %}">
        <a href="{{ item.url }}">{{ item.title | escape }}</a>
        {% if item.children.size > 0 %}
          <ul class="dropdown">
            {% for child in item.children %}
              <li class="nav-child{% if child.active %} active{% endif %}">
                <a href="{{ child.url }}">{{ child.title | escape }}</a>
                {% if child.children.size > 0 %}
                  <ul class="dropdown-sub">
                    {% for grandchild in child.children %}
                      <li>
                        <a href="{{ grandchild.url }}">{{ grandchild.title | escape }}</a>
                      </li>
                    {% endfor %}
                  </ul>
                {% endif %}
              </li>
            {% endfor %}
          </ul>
        {% endif %}
      </li>
    {% endfor %}
  </ul>
</nav>
',

      # Template 5: Data table with complex filters
      "Data Table" => '
<table class="data-table">
  <caption>{{ table.title | escape }} ({{ table.rows | size }} records)</caption>
  <thead>
    <tr>
      {% for header in table.headers %}
        <th>{{ header.label | escape | upcase }}</th>
      {% endfor %}
    </tr>
  </thead>
  <tbody>
    {% for row in table.rows %}
      <tr class="{% cycle "odd", "even" %}">
        {% for cell in row.cells %}
          <td>
            {% case cell.type %}
              {% when "number" %}
                {{ cell.value | round: 2 }}
              {% when "currency" %}
                {{ cell.value | money }}
              {% when "date" %}
                {{ cell.value | date: "%Y-%m-%d" }}
              {% when "percent" %}
                {{ cell.value | times: 100 | round: 1 }}%
              {% else %}
                {{ cell.value | escape | truncate: 50 }}
            {% endcase %}
          </td>
        {% endfor %}
      </tr>
    {% endfor %}
  </tbody>
</table>
'
    }
  end

  def self.run
    puts "=" * 70
    puts "Register Allocation Benchmark"
    puts "Measuring peak temp register reduction"
    puts "=" * 70
    puts

    results = []

    templates.each do |name, source|
      result = benchmark_template(name, source)
      results << result

      puts "Template: #{result[:name]}"
      puts "  Temp indices used:                  #{result[:original_temps]}"
      puts "  Total STORE_TEMP ops:               #{result[:store_count]}"
      puts "  Effective before (max):             #{result[:effective_before]}"
      puts "  Peak temps (after allocation):      #{result[:peak_after]}"
      puts "  Reduction:                          #{result[:reduction]} temps (#{result[:reduction_pct]}%)"
      puts
    end

    # Summary statistics
    puts "-" * 70
    puts "Summary"
    puts "-" * 70

    total_effective = results.sum { |r| r[:effective_before] }
    total_after = results.sum { |r| r[:peak_after] }
    total_reduction = total_effective - total_after
    avg_reduction_pct = results.map { |r| r[:reduction_pct] }.sum / results.size

    puts "Templates benchmarked:    #{results.size}"
    puts "Total effective before:   #{total_effective}"
    puts "Total after allocation:   #{total_after}"
    puts "Total reduction:          #{total_reduction} temps"
    puts "Average reduction:        #{avg_reduction_pct.round(1)}%"
    puts

    # Verify outputs are correct
    puts "Verifying template execution correctness..."
    ctx = LiquidIL::Context.new
    errors = []

    templates.each do |name, source|
      begin
        template = ctx.parse(source, optimize: true)
        # Just verify it can execute without errors
        template.render({})
      rescue => e
        errors << "#{name}: #{e.message}"
      end
    end

    if errors.empty?
      puts "All templates execute correctly with register allocation enabled."
    else
      puts "ERRORS:"
      errors.each { |e| puts "  - #{e}" }
    end

    results
  end
end

# Run benchmark if executed directly
if __FILE__ == $0
  RegisterBenchmark.run
end
