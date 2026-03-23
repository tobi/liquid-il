# frozen_string_literal: true

source "https://rubygems.org"

gem "liquid-spec", git: "https://github.com/Shopify/liquid-spec", ref: "9d6797079f9fe107f4be25c29637ff25e27d0da5"
gem "liquid", git: "https://github.com/Shopify/liquid"
gem "base64"
gem "rake"
gem "minitest"

# Load local-only dependencies (gitignored)
local_gemfile = File.join(__dir__, "Gemfile.local")
eval_gemfile(local_gemfile) if File.exist?(local_gemfile)
