# Optional Shopify/liquid-vm comparison

Shopify/liquid-vm is a private repository, so LiquidIL does not depend on it and never runs it in default CI. If you have access, the rake tasks below clone/update it under `/tmp/liquid-vm` by default and run liquid-spec with liquid-vm's own adapter.

## One-time setup

```sh
bundle exec rake liquid_vm:setup
```

Configuration knobs:

- `LIQUID_VM_PATH=/path/to/liquid-vm` — use a different checkout path (default: `/tmp/liquid-vm`).
- `LIQUID_VM_REPO=https://github.com/Shopify/liquid-vm` — clone URL override.
- `LIQUID_VM_ADAPTER=/path/to/adapter.rb` — use an explicit liquid-spec adapter.
- `LIQUID_VM_BACKEND=ssa` — use `test/adapters/liquid_vm_ssa.rb` from the checkout.

## Run specs against LiquidIL

```sh
bundle exec rake liquid_vm:spec
```

This runs a liquid-spec matrix with Shopify/liquid-vm and `spec/liquid_il.rb`.
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

The benchmark task runs liquid-spec's benchmark suite with `liquid_ruby`, Shopify/liquid-vm, and LiquidIL. It uses the liquid-vm checkout's `Gemfile` via `BUNDLE_GEMFILE=/tmp/liquid-vm/Gemfile` and defaults `BUNDLE_WITHOUT=development`, so private development-only dependencies stay out of this repository's committed `Gemfile.lock`.

## Include in the regular matrix explicitly

The committed `spec/liquid_vm.rb` is only an optional shim. The normal `rake matrix` skips it unless explicitly enabled:

```sh
WITH_LIQUID_VM=1 LIQUID_VM_PATH=/tmp/liquid-vm bundle exec rake matrix
```

For this mode, make sure your current bundle can `require "liquid-vm"` (for example via a local, uncommitted `Gemfile.local`). The dedicated `liquid_vm:*` tasks are usually easier because they run under the liquid-vm checkout's bundle.
