# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../..", __dir__))
require_relative "app"

run LiquidILWeb::App.new
