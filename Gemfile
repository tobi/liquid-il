# frozen_string_literal: true

source "https://rubygems.org"

gem "liquid-spec", git: "https://github.com/Shopify/liquid-spec"
gem "liquid", git: "https://github.com/Shopify/liquid"
# liquid-spec's reference adapter uses ActiveSupport to mirror Shopify's
# benchmark environment. Keep it explicit so multi-adapter bench runs cannot
# silently drop the reference process when that adapter boots.
gem "activesupport", require: false
gem "base64"
gem "rake"
gem "minitest"

# Load local-only dependencies (gitignored)
local_gemfile = File.join(__dir__, "Gemfile.local")
eval_gemfile(local_gemfile) if File.exist?(local_gemfile)
