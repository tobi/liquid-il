# frozen_string_literal: true

source "https://rubygems.org"

gem "liquid-spec", git: "https://github.com/Shopify/liquid-spec"
gem "liquid", git: "https://github.com/Shopify/liquid"
gem "base64"
gem "rake"
gem "minitest"

# Load local-only dependencies (gitignored)
local_gemfile = File.join(__dir__, "Gemfile.local")
eval_gemfile(local_gemfile) if File.exist?(local_gemfile)
