# Optional Shopify/liquid-vm comparison

Shopify/liquid-vm is a private repository, so LiquidIL does not depend on it and never runs it in default CI. If you have access, the rake tasks below clone/update it under `/tmp/liquid-vm` by default and run liquid-spec with liquid-vm's own adapter.

## One-time setup

```sh
bundle exec rake liquid_vm:setup
```

`liquid_vm:setup` runs `bundle install` and `rake compile` inside the checkout, so it needs the liquid-vm native build prerequisites (notably Rust/Cargo).

Configuration knobs:

- `LIQUID_VM_PATH=/path/to/liquid-vm` — use a different checkout path (default: `/tmp/liquid-vm`).
- `LIQUID_VM_REPO=https://github.com/Shopify/liquid-vm` — clone URL override.
- `LIQUID_VM_ADAPTER=/path/to/adapter.rb` — use an explicit classic VM liquid-spec adapter.
- `LIQUID_VM_SSA_ADAPTER=/path/to/adapter.rb` — use an explicit SSA VM liquid-spec adapter.
- `LIQUID_VM_BACKEND=ssa` — make `spec/liquid_vm.rb` target SSA for one-off manual runs. The rake matrix/bench tasks always include classic VM and SSA as separate adapters.

## Run specs against LiquidIL

```sh
bundle exec rake liquid_vm:spec
```

This runs a JIT-enabled liquid-spec matrix with `liquid_ruby`, `spec/liquid_il.rb`, Shopify/liquid-vm classic, and Shopify/liquid-vm SSA.
Pass liquid-spec filters with environment variables:

```sh
NAME=for bundle exec rake liquid_vm:spec
SUITE=partials bundle exec rake liquid_vm:spec
LIQUID_SPEC_ARGS="--verbose" bundle exec rake liquid_vm:spec
```

## Run benchmarks

```sh
bundle exec rake liquid_vm:bench
# alias:
bundle exec rake bench:liquid_vm
```

The benchmark task runs liquid-spec's benchmark suite with JIT enabled for `liquid_ruby`, LiquidIL, Shopify/liquid-vm classic, and Shopify/liquid-vm SSA. Setup uses the liquid-vm checkout's `Gemfile` via `BUNDLE_GEMFILE=/tmp/liquid-vm/Gemfile` and defaults `BUNDLE_WITHOUT=development`; the actual matrix/bench run uses this repository's liquid-spec so LiquidIL's artifact benchmark hooks are available. The task also prepends `/tmp/liquid-vm/gem/lib` to `RUBYLIB` so the built native extension can be loaded without committing private dependencies to this repository's `Gemfile.lock`.

## Include in the regular matrix explicitly

The committed `spec/liquid_vm.rb` is only an optional shim. The normal `rake matrix` skips it unless explicitly enabled:

```sh
WITH_LIQUID_VM=1 LIQUID_VM_PATH=/tmp/liquid-vm bundle exec rake matrix
```

For this mode, make sure your current bundle can `require "liquid-vm"` (for example via a local, uncommitted `Gemfile.local`). The dedicated `liquid_vm:*` tasks are usually easier because they run under the liquid-vm checkout's bundle. `WITH_LIQUID_VM=1` includes both `spec/liquid_vm.rb` and `spec/liquid_vm_ssa.rb`.
