# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/liquid_il"

# These tests make concurrency bugs observable: they share compiled templates
# across rendering threads, mint class-cache entries from many compiling
# threads, and force the ISeq cache's size-based clear path while renders run.
class ConcurrencyTest < Minitest::Test
  class FS
    def initialize(templates)
      @templates = templates
    end

    def read_template_file(name, _context = nil)
      @templates[name.to_s]
    end
  end

  THREADS = 8

  def setup
    clear_compiler_caches
  end

  def test_shared_template_render_has_per_render_state
    ctx = LiquidIL::Context.new(file_system: FS.new("card" => "P{{ value }}"))
    template = ctx.parse(
      "T{{ tid }}:{% capture cap %}C{{ tid }}{% endcapture %}{{ cap }}|" \
      "{% for item in items %}{{ forloop.index }}={{ item }}:{% cycle \"x\",\"y\" %}:" \
      "{% ifchanged %}{{ group }}{% endifchanged %};{% endfor %}" \
      "|{% increment counter %}/{% decrement counter %}|{% render \"card\", value: tid %}"
    )

    failures = Queue.new
    threads = THREADS.times.map do |tid|
      Thread.new do
        30.times do
          assigns = {
            "tid" => tid,
            "group" => "g#{tid}",
            "items" => ["a#{tid}", "b#{tid}", "c#{tid}"],
          }
          expected = "T#{tid}:C#{tid}|1=a#{tid}:x:g#{tid};2=b#{tid}:y:;3=c#{tid}:x:;|0/0|P#{tid}"
          actual = template.render(assigns)
          failures << [tid, actual] unless actual == expected
        end
      end
    end
    join_threads!(threads, timeout: 3)

    assert_queue_empty failures, "shared Template render leaked state"
  end

  def test_concurrent_compilation_mints_partial_and_name_cache_entries
    assert_concurrent_compilation(thread_count: THREADS, templates_per_thread: 6, timeout: 4)
  end

  def test_concurrent_compilation_under_gc_stress
    old = GC.stress
    GC.stress = true
    assert_concurrent_compilation(thread_count: 2, templates_per_thread: 1, timeout: 9)
  ensure
    GC.stress = old
  end

  def test_iseq_cache_eviction_races_with_render
    prefill_iseq_cache
    render_template = LiquidIL.parse("R{{ tid }}:{% for item in items %}{{ item }}{% endfor %}")
    failures = Queue.new

    renderers = 2.times.map do |tid|
      Thread.new do
        30.times do
          actual = render_template.render("tid" => tid, "items" => [tid, tid + 1])
          expected = "R#{tid}:#{tid}#{tid + 1}"
          failures << [:render, tid, actual] unless actual == expected
        end
      end
    end

    compilers = THREADS.times.map do |tid|
      Thread.new do
        1.times do |i|
          template = LiquidIL.parse("C#{tid}-#{i}:{{ value | plus: #{i} }}")
          expected = "C#{tid}-#{i}:#{tid + i}"
          actual = template.render("value" => tid)
          failures << [:compile, tid, i, actual] unless actual == expected
        end
      end
    end

    join_threads!(renderers + compilers, timeout: 3)
    assert_queue_empty failures, "ISeq cache eviction raced with render/compile"
  end

  private

  def assert_concurrent_compilation(thread_count:, templates_per_thread:, timeout:)
    failures = Queue.new
    threads = thread_count.times.map do |tid|
      Thread.new do
        templates_per_thread.times do |i|
          partials = {
            "row" => "R#{tid}-#{i}:{{ value | plus: #{tid} }}:{{ product.details.title }}",
            "outer" => "O#{tid}-#{i}[{% render 'row', value: value, product: product %}]",
          }
          ctx = LiquidIL::Context.new(file_system: FS.new(partials))
          template = ctx.parse(
            "T#{tid}-#{i}|{% render 'row', value: value, product: product %}|" \
            "{% render 'outer', value: value, product: product %}|{{ product.details.title }}"
          )
          assigns = {
            "value" => i,
            "product" => { "details" => { "title" => "p#{tid}-#{i}" } },
          }
          row = "R#{tid}-#{i}:#{i + tid}:p#{tid}-#{i}"
          expected = "T#{tid}-#{i}|#{row}|O#{tid}-#{i}[#{row}]|p#{tid}-#{i}"
          actual = template.render(assigns)
          failures << [tid, i, actual] unless actual == expected
        end
      end
    end
    join_threads!(threads, timeout: timeout)

    assert_queue_empty failures, "concurrent compilation served the wrong cached body/name"
  end

  def assert_queue_empty(queue, message)
    return if queue.empty?

    flunk "#{message}: #{queue.pop(true).inspect}"
  end

  def join_threads!(threads, timeout:)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    threads.each(&:join)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    assert_operator elapsed, :<, timeout, "concurrency test exceeded #{timeout}s (#{format('%.2f', elapsed)}s)"
  end

  def clear_compiler_caches
    compiler = LiquidIL::RubyCompiler
    {
      ISEQ_CACHE_MUTEX: :@@iseq_cache,
      PARTIAL_CACHE_MUTEX: :@@partial_cache,
      INDENT_PARTIAL_BODY_CACHE_MUTEX: :@@indent_partial_body_cache,
      NAME_REGISTRY_MUTEX: [:@@frozen_array_names, :@@partial_loop_bases],
    }.each do |mutex_name, vars|
      mutex = compiler.const_get(mutex_name)
      Array(vars).each do |var|
        mutex.synchronize { compiler.class_variable_get(var).clear }
      end
    end
  end

  def prefill_iseq_cache
    compiler = LiquidIL::RubyCompiler
    mutex = compiler.const_get(:ISEQ_CACHE_MUTEX)
    cache = compiler.class_variable_get(:@@iseq_cache)
    mutex.synchronize do
      cache.clear
      1000.times { |i| cache[i] = "dummy".b.freeze }
    end
  end
end
