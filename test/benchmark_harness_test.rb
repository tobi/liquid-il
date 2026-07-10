# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "rake"
require "liquid/spec/cli/benchmark"

# Integration guards for the liquid-spec benchmark contract consumed by the
# custom scenario table in Rakefile. The canonical scenario numbers are atomic
# same-process workflows; adding independently measured parse/render stages
# would produce a number that was never timed.
load File.expand_path("../Rakefile", __dir__)

class BenchmarkHarnessTest < Minitest::Test
  def test_scenario_metrics_prefer_atomic_workflows
    row = {
      workflows: {
        source_compile_render: { mean: 0.000_321 },
        artifact_load_first_render: { mean: 0.000_087 },
      },
      parse: { mean: 0.010 },
      render: { mean: 0.020 },
      artifact: { load_mean: 0.030, bytes: 12_345 },
    }

    metrics = CacheScenarios.scenario_metrics(row)

    assert_equal 0.000_321, metrics[:cache_miss]
    assert_equal 0.000_087, metrics[:remote_hit]
    assert_equal 0.020, metrics[:in_process]
    assert_equal 12_345, metrics[:artifact_bytes]
  end

  def test_scenario_metrics_keep_legacy_stage_sum_fallback
    row = {
      parse: { mean: 0.000_300 },
      render: { mean: 0.000_020 },
      artifact: { load_mean: 0.000_060, bytes: 4_096 },
    }

    metrics = CacheScenarios.scenario_metrics(row)

    assert_in_delta 0.000_320, metrics[:cache_miss], 1e-12
    assert_in_delta 0.000_080, metrics[:remote_hit], 1e-12
  end

  def test_jsonl_compaction_preserves_sub_microsecond_precision_and_integer_nanoseconds
    benchmark = Liquid::Spec::CLI::Benchmark
    value = {
      mean: 0.000_000_432_123,
      batches: [{ iterations: 5, elapsed_ns: 2_161 }],
      omitted: nil,
    }

    roundtrip = JSON.parse(JSON.generate(benchmark.compact(value)))

    assert_equal 0.000_000_432_123, roundtrip.fetch("mean")
    assert_equal 2_161, roundtrip.dig("batches", 0, "elapsed_ns")
    refute roundtrip.key?("omitted")
  end

  def test_jsonl_validation_rejects_a_silently_missing_adapter_process
    jsonl = [
      {
        type: "run_metadata",
        adapter: "liquid_il",
        workflow_execution_model: "same_process",
        workflow_process_isolated: false,
        forked_workflows: false,
        artifact_protocol: true,
      },
      {
        type: "spec",
        adapter: "liquid_il",
        spec: "bench_example",
        status: "success",
        workflows: {
          source_compile_render: { mean: 0.001, freshness: "same_process_compile_each_sample" },
          artifact_load_first_render: { mean: 0.0005, freshness: "same_process_load_each_sample" },
        },
        artifact: { bytes: 100 },
      },
    ].map { |event| JSON.generate(event) }.join("\n")

    error = nil
    _stdout, _stderr = capture_io do
      error = assert_raises(SystemExit) do
        CacheScenarios.validate_jsonl!(jsonl, expected_adapters: %w[liquid_ruby liquid_il])
      end
    end

    assert_equal 1, error.status
  end
end
