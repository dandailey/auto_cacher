require "active_record"
require "active_support"
require "auto_cacher"

ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
ActiveRecord::Schema.verbose = false
ActiveRecord::Schema.define do
  create_table :customers do |t|
    t.string :name
    t.integer :unfulfilled_order_count, default: 0
  end

  create_table :orders do |t|
    t.integer :customer_id
    t.string :status
  end

  create_table :accounts do |t|
    t.string :name
  end

  create_table :account_caches do |t|
    t.integer :account_id, null: false, index: {unique: true}
    t.integer :order_count, default: 0
  end
end

ActiveRecord::Base.include(HallMonitor::ActiveRecordExtensions)
ActiveRecord::Base.include(AutoCacher::ActiveRecordExtensions)

RSpec.configure do |config|
  # Enable flags like --only-failures and --next-failure
  config.example_status_persistence_file_path = ".rspec_status"

  # Disable RSpec exposing methods globally on `Module` and `main`
  config.disable_monkey_patching!

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end
end
