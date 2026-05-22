#!/bin/bash
set -euo pipefail

# Run quick unit tests (not full liquid-spec, which takes too long)
cd "$(dirname "$0")"

# Quick syntax check
ruby -c lib/liquid_il.rb 2>&1 || exit 1
ruby -c lib/liquid_il/lexer.rb 2>&1 || exit 1
ruby -c lib/liquid_il/parser.rb 2>&1 || exit 1
ruby -c lib/liquid_il/compiler.rb 2>&1 || exit 1
ruby -c lib/liquid_il/ruby_compiler.rb 2>&1 || exit 1
ruby -c lib/liquid_il/il.rb 2>&1 || exit 1
ruby -c lib/liquid_il/passes.rb 2>&1 || exit 1
ruby -c lib/liquid_il/optimizer.rb 2>&1 || exit 1

# Run quick unit tests (skip slow ones)
bundle exec ruby -Ilib test/liquid_il_test.rb 2>&1 | tail -5 || exit 1
