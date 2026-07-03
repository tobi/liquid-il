# frozen_string_literal: true

source "https://rubygems.org"

# TEMP: local checkout until the local-suites commit (edfd3d6) is pushed upstream
gem "liquid-spec", path: "#{Dir.home}/src/github.com/Shopify/liquid-spec"
gem "liquid", git: "https://github.com/Shopify/liquid"
gem "base64"
gem "rake"
gem "minitest"

# Load local-only dependencies (gitignored)
local_gemfile = File.join(__dir__, "Gemfile.local")
eval_gemfile(local_gemfile) if File.exist?(local_gemfile)
