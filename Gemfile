# frozen_string_literal: true

source "https://rubygems.org"

# Specify your gem's dependencies in auto_cacher.gemspec
gemspec

gem "rake", "~> 13.0"

# Development dependencies
group :development, :test do
  gem "byebug", "~> 11.1"
  gem "simplecov", "~> 0.22"
  gem "sqlite3", ">= 1.6"
end

# HallMonitor comes from GitHub: an unrelated gem with the same name exists on RubyGems.
# Set HALL_MONITOR_PATH to develop against a local checkout.
if ENV["HALL_MONITOR_PATH"].to_s.empty?
  gem "hall_monitor", git: "https://github.com/dandailey/hall_monitor.git"
else
  gem "hall_monitor", path: ENV["HALL_MONITOR_PATH"]
end
