# frozen_string_literal: true

Gem::Specification.new do |spec|
  spec.name          = "liquid-il"
  spec.version       = "0.1.0"
  spec.authors       = ["Tobias Lütke"]
  spec.email         = ["tobi@shopify.com"]

  spec.summary       = "IL-based Liquid template compiler targeting Ruby/YJIT"
  spec.description   = "Compiles Liquid templates to an intermediate language, then to optimized Ruby source that runs natively on YJIT."
  spec.homepage      = "https://github.com/tobi/liquid-il"
  spec.license       = "MIT"

  spec.required_ruby_version = ">= 3.1"

  spec.files         = Dir["lib/**/*.rb", "LICENSE", "README.md"]
  spec.require_paths = ["lib"]
end
