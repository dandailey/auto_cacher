require "rails_helper"

class Customer < ActiveRecord::Base; end

class Order < ActiveRecord::Base; end

class Customer::UnfulfilledOrderCountCacher < AutoCacher::Cacher
  configuration(
    watching: {Order => [:customer_id, :status]},
    calculation: ->(customer) { Order.where(customer_id: customer.id, status: "unfulfilled").count },
    records_to_update: ->(data_change) {
      ids = [data_change.record.customer_id]
      ids << data_change.old_value_for(:customer_id) if data_change.field_changed?(:customer_id)
      Customer.where(id: ids.compact.uniq)
    }
  )
end

class Customer::SymbolCacher < AutoCacher::Cacher
  configuration(records_to_update: :affected_by)
end

class Customer::CallbackCacher < AutoCacher::Cacher
  configuration(on_update: ->(customer) { customer.name = "updated" })
end

class AccountCache < ActiveRecord::Base
  auto_cacher_dedicated_to :account
end

class Account < ActiveRecord::Base
  has_dedicated_auto_cacher :account_cache, inverse_of: :account
end

class AccountCache::OrderCountCacher < AutoCacher::Cacher
  configuration(
    watching: {"orders" => nil},
    calculation: ->(_cache) { Order.count },
    records_to_update: ->(_data_change) { AccountCache.all }
  )
end

RSpec.describe "AutoCacher against a database" do
  let(:cacher) { Customer::UnfulfilledOrderCountCacher.new }
  let(:customer) { Customer.create!(name: "a") }
  let(:other_customer) { Customer.create!(name: "b") }

  before do
    [AccountCache, Account, Order, Customer].each(&:delete_all)

    @saved_cachers = AutoCacher.registered_cachers.dup
    @saved_callbacks = AutoCacher.instance_variable_get(:@callbacks_for_after_every_recalculation)
    AutoCacher.instance_variable_set(:@registered_cachers, [])
    AutoCacher.instance_variable_set(:@callbacks_for_after_every_recalculation, [])
    AutoCacher.register_cacher(cacher)

    HallMonitor.configure { |config| config.emitter = ->(data_change) { HallMonitor.consume_data_change(data_change) } }
    HallMonitor.watchers.clear
  end

  after do
    AutoCacher.instance_variable_set(:@registered_cachers, @saved_cachers)
    AutoCacher.instance_variable_set(:@callbacks_for_after_every_recalculation, @saved_callbacks)
    HallMonitor.watchers.clear
  end

  def watch(watched_cacher)
    HallMonitor.register_watcher(
      HallMonitor::Watcher.new(
        field_map: watched_cacher.watching,
        operations: watched_cacher.operations,
        callback: ->(data_change) { watched_cacher.call(data_change) }
      )
    )
  end

  describe ".build_changes_queue" do
    it "lists the differences between cached and calculated values" do
      Order.insert_all!([{customer_id: customer.id, status: "unfulfilled"}])

      queue = AutoCacher.build_changes_queue(Customer.where(id: customer.id), [:unfulfilled_order_count])

      expect(queue.size).to eq(1)
      expect(queue.first[:record]).to eq(customer)
      expect(queue.first[:changes][:unfulfilled_order_count]).to include(old_value: 0, new_value: 1, cacher: cacher)
    end

    it "is empty when the cached value is current" do
      expect(AutoCacher.build_changes_queue(Customer.where(id: customer.id), [:unfulfilled_order_count])).to be_empty
    end
  end

  describe ".recalculate" do
    before { Order.insert_all!([{customer_id: customer.id, status: "unfulfilled"}]) }

    it "updates the cached field" do
      AutoCacher.recalculate(Customer.where(id: customer.id), [:unfulfilled_order_count])

      expect(customer.reload.unfulfilled_order_count).to eq(1)
    end

    it "runs callbacks with the details of the change" do
      details = []
      AutoCacher.after_every_recalculation { |detail| details << detail }

      AutoCacher.recalculate(Customer.where(id: customer.id), [:unfulfilled_order_count])

      expect(details.size).to eq(1)
      expect(details.first).to include(record: customer, field: :unfulfilled_order_count, old_value: 0, new_value: 1, cacher: cacher)
    end

    it "leaves a current record alone" do
      AutoCacher.recalculate(Customer.where(id: customer.id), [:unfulfilled_order_count])
      details = []
      AutoCacher.after_every_recalculation { |detail| details << detail }

      expect { AutoCacher.recalculate(Customer.where(id: customer.id), [:unfulfilled_order_count]) }
        .not_to change { Customer.find(customer.id).attributes }
      expect(details).to be_empty
    end

    it "does nothing without fields" do
      AutoCacher.recalculate(Customer.where(id: customer.id), [])

      expect(customer.reload.unfulfilled_order_count).to eq(0)
    end
  end

  describe "reacting to data changes through HallMonitor" do
    let!(:order_model) do
      Class.new(ActiveRecord::Base) do
        self.table_name = "orders"
        include HallMonitor::ActiveRecordExtensions
        def self.name = "Order"
      end
    end

    before { watch(cacher) }

    it "keeps the cache current through a record's whole life" do
      order = order_model.create!(customer_id: customer.id, status: "unfulfilled")
      expect([customer.reload.unfulfilled_order_count, other_customer.reload.unfulfilled_order_count]).to eq([1, 0])

      order_model.find(order.id).update!(customer_id: other_customer.id)
      expect([customer.reload.unfulfilled_order_count, other_customer.reload.unfulfilled_order_count]).to eq([0, 1])

      order_model.find(order.id).update!(status: "done")
      expect(other_customer.reload.unfulfilled_order_count).to eq(0)

      order_model.find(order.id).update!(status: "unfulfilled")
      expect(other_customer.reload.unfulfilled_order_count).to eq(1)

      order_model.find(order.id).destroy!
      expect(other_customer.reload.unfulfilled_order_count).to eq(0)
    end

    it "ignores fields it is not watching" do
      customer
      data_change = HallMonitor::DataChange.new(table: "orders", operation: :update, changes: {"unwatched" => [1, 2]})

      expect(cacher).not_to receive(:recalculate_for)
      HallMonitor.consume_data_change(data_change)
    end
  end

  describe "cacher configuration" do
    it "infers the table, field and class from the cacher's name" do
      expect(cacher.table).to eq("customers")
      expect(cacher.field).to eq(:unfulfilled_order_count)
      expect(cacher.klass).to eq(Customer)
    end

    it "calls a records_to_update symbol as a method on the cached class" do
      allow(Customer).to receive(:affected_by).and_return(Customer.none)
      data_change = HallMonitor::DataChange.new(table: "orders", changes: {})

      Customer::SymbolCacher.new.call(data_change)

      expect(Customer).to have_received(:affected_by).with(data_change)
    end

    it "runs on_update after recalculating" do
      Customer::CallbackCacher.new.run_callback(customer)

      expect(customer.name).to eq("updated")
    end
  end

  describe "dedicated models" do
    let(:account) { Account.create!(name: "a") }
    let(:dedicated_cacher) { AccountCache::OrderCountCacher.new }

    before { AutoCacher.register_cacher(dedicated_cacher) }

    it "creates the dedicated record on first access and reuses it" do
      expect { account.account_cache }.to change { AccountCache.count }.by(1)
      expect { Account.find(account.id).account_cache }.not_to change { AccountCache.count }
      expect(account.account_cache.account).to eq(account)
    end

    it "runs after_dedicated_model_creation once" do
      created = []
      AutoCacher.after_dedicated_model_creation { |record| created << record }

      account.account_cache
      Account.find(account.id).account_cache

      expect(created).to eq([account.account_cache])
    ensure
      AutoCacher.instance_variable_get(:@callbacks_for_after_dedicated_model_creation).pop
    end

    it "links the primary and dedicated models in both directions" do
      expect(account.dedicated_auto_cacher).to eq(account.account_cache)
      expect(account.account_cache.auto_cacher_dedicated_to).to eq(account)
      expect(Account.has_dedicated_auto_cacher?).to be true
      expect(AccountCache.is_dedicated_auto_cacher?).to be true
      expect(Account.dedicated_auto_cacher_klass).to eq(AccountCache)
      expect(AccountCache.auto_cacher_dedicated_to_klass).to eq(Account)
      expect(AutoCacher.models_with_dedicated_auto_cachers).to include(Account)
    end

    it "finds the dedicated class from a class or a record" do
      expect(AutoCacher.dedicated_auto_cacher_klass_for(Account)).to eq(AccountCache)
      expect(AutoCacher.dedicated_auto_cacher_klass_for(account)).to eq(AccountCache)
    end

    it "populates and saves its cached fields" do
      Order.insert_all!([{status: "x"}, {status: "y"}])

      account.account_cache.auto_cacher_populate_and_save!

      expect(AccountCache.find_by(account_id: account.id).order_count).to eq(2)
    end

    it "recalculates the dedicated record" do
      cache = account.account_cache
      Order.insert_all!([{status: "x"}])

      dedicated_cacher.call(HallMonitor::DataChange.new(table: "orders", changes: {"status" => [nil, "x"]}))

      expect(cache.reload.order_count).to eq(1)
    end

    it "destroys the dedicated record with its primary record" do
      account.account_cache

      expect { account.destroy! }.to change { AccountCache.count }.by(-1)
    end

    it "requires inverse_of" do
      expect { Class.new(ActiveRecord::Base) { has_dedicated_auto_cacher :thing } }.to raise_error(ArgumentError, /inverse_of/)
    end

    it "keeps each model's list of dedicated cachers separate" do
      expect(Customer.auto_cacher_list).to be_empty
      expect(Account.auto_cacher_list).to eq([:account_cache])
    end
  end
end
