require File.dirname(__FILE__) + '/spec_helper.rb'

include RR

describe ReplicationInitializer do
  before(:each) do
    Initializer.configuration = standard_config
  end

  after(:each) do
  end

  it "initializer should store the session" do
    session = Session.new
    initializer = ReplicationInitializer.new session
    initializer.session.should == session
  end

  it "options should return the table specific options if table is given" do
    session = Session.new deep_copy(Initializer.configuration)
    initializer = ReplicationInitializer.new session
    session.configuration.should_receive(:options_for_table).
      with('my_table').
      and_return(:dummy_options)
    initializer.options('my_table').should == :dummy_options
  end

  it "options should return the general options if no table is given" do
    session = Session.new deep_copy(Initializer.configuration)
    initializer = ReplicationInitializer.new session
    session.configuration.should_receive(:options).
      and_return(:dummy_options)
    initializer.options.should == :dummy_options
  end

  it "create_trigger should create a working trigger" do
    session = nil
    begin
      session = Session.new
      session.left.begin_db_transaction
      initializer = ReplicationInitializer.new(session)
      initializer.create_trigger(:left, 'trigger_test')

      session.left.insert_record 'trigger_test', {
        'first_id' => 1,
        'second_id' => 2,
        'name' => 'bla'
      }

      row = session.left.select_one("select * from rr_change_log")
      row.delete 'id'
      row.delete 'change_time'
      row.should == {
        'change_table' => 'trigger_test',
        'change_key' => 'first_id|1|second_id|2',
        'change_new_key' => nil,
        'change_type' => 'I'
      }
    ensure
      session.left.execute 'delete from trigger_test' if session
      session.left.execute 'delete from rr_change_log' if session
      session.left.rollback_db_transaction if session
    end
  end

  it "trigger_exists? and drop_trigger should work correctly" do
    session = nil
    begin
      session = Session.new
      initializer = ReplicationInitializer.new(session)
      if initializer.trigger_exists?(:left, 'trigger_test')
        initializer.drop_trigger(:left, 'trigger_test')
      end
      session.left.begin_db_transaction

      initializer.create_trigger :left, 'trigger_test'
      initializer.trigger_exists?(:left, 'trigger_test').
        should be_true
      initializer.drop_trigger(:left, 'trigger_test')
      initializer.trigger_exists?(:left, 'trigger_test').
        should be_false
    ensure
      session.left.rollback_db_transaction if session
    end
  end

  it "ensure_sequence_setup should ensure that a table's auto generated ID values have the correct increment and offset" do
    session = nil
    begin
      session = Session.new
      initializer = ReplicationInitializer.new(session)
      session.left.begin_db_transaction
      session.right.begin_db_transaction

      # Note:
      # Calling ensure_sequence_setup twice with different values to ensure that
      # it is actually does something.

      table_pair = {:left => 'sequence_test', :right => 'sequence_test'}

      initializer.ensure_sequence_setup table_pair, 3, 2, 2
      initializer.ensure_sequence_setup table_pair, 5, 2, 1
      id1, id2 = get_example_sequence_values(session)
      (id2 - id1).should == 5
      (id1 % 5).should == 2
    ensure
      [:left, :right].each do |database|
        initializer.clear_sequence_setup database, 'sequence_test' if session
        session.send(database).execute "delete from sequence_test" if session
        session.send(database).rollback_db_transaction if session
      end
    end
  end

  it "clear_sequence_setup should remove custom sequence settings" do
    session = nil
    begin
      session = Session.new
      initializer = ReplicationInitializer.new(session)
      session.left.begin_db_transaction
      session.right.begin_db_transaction
      table_pair = {:left => 'sequence_test', :right => 'sequence_test'}
      initializer.ensure_sequence_setup table_pair, 5, 2, 2
      initializer.clear_sequence_setup :left, 'sequence_test'
      id1, id2 = get_example_sequence_values(session)
      (id2 - id1).should == 1
    ensure
      [:left, :right].each do |database|
        initializer.clear_sequence_setup database, 'sequence_test' if session
        session.send(database).execute "delete from sequence_test" if session
        session.send(database).rollback_db_transaction if session
      end
    end
  end

  it "change_log_exists? should return true if replication log exists" do
    config = deep_copy(standard_config)
    initializer = ReplicationInitializer.new(Session.new(config))
    initializer.change_log_exists?(:left).should be_true
    config.options[:rep_prefix] = 'r2'
    initializer = ReplicationInitializer.new(Session.new(config))
    initializer.change_log_exists?(:left).should be_false
  end

  it "event_log_exists? should return true if event log exists" do
    config = deep_copy(standard_config)
    initializer = ReplicationInitializer.new(Session.new(config))
    initializer.event_log_exists?.should be_true
    config.options[:rep_prefix] = 'r2'
    initializer = ReplicationInitializer.new(Session.new(config))
    initializer.event_log_exists?.should be_false
  end

  it "create_event_log / drop_event_log should create / drop the event log" do
    config = deep_copy(standard_config)
    config.options[:rep_prefix] = 'r2'
    session = Session.new(config)
    initializer = ReplicationInitializer.new(session)
    initializer.drop_event_log if initializer.event_log_exists?

    $stderr.stub! :write
    initializer.event_log_exists?.should be_false
    initializer.create_event_log
    initializer.event_log_exists?.should be_true

    # verify that replication log has 8 byte, auto-generating primary key
    session.left.insert_record 'r2_event_log', {'id' => 1e18.to_i, 'change_key' => 'blub'}
    session.left.select_one("select id from r2_event_log where change_key = 'blub'")['id'].
      to_i.should == 1e18.to_i

    initializer.drop_event_log
    initializer.event_log_exists?.should be_false
  end

  it "create_change_log / drop_change_log should create / drop the replication log" do
    config = deep_copy(standard_config)
    config.options[:rep_prefix] = 'r2'
    session = Session.new(config)
    initializer = ReplicationInitializer.new(session)
    initializer.drop_change_log(:left) if initializer.change_log_exists?(:left)

    $stderr.stub! :write
    initializer.change_log_exists?(:left).should be_false
    initializer.create_change_log(:left)
    initializer.change_log_exists?(:left).should be_true

    # verify that replication log has 8 byte, auto-generating primary key
    session.left.insert_record 'r2_change_log', {'change_key' => 'bla'}
    session.left.select_one("select id from r2_change_log where change_key = 'bla'")['id'].
      to_i.should > 0
    session.left.insert_record 'r2_change_log', {'id' => 1e18.to_i, 'change_key' => 'blub'}
    session.left.select_one("select id from r2_change_log where change_key = 'blub'")['id'].
      to_i.should == 1e18.to_i

    initializer.drop_change_log(:left)
    initializer.change_log_exists?(:left).should be_false
  end

  it "ensure_activity_marker_tables should not create the tables if they already exist" do
    session = Session.new
    initializer = ReplicationInitializer.new(session)
    session.left.should_not_receive(:create_table)
    initializer.ensure_activity_marker_tables
  end

  it "ensure_activity_marker_tables should create the marker tables" do
    begin
      config = deep_copy(standard_config)
      config.options[:rep_prefix] = 'rx'
      session = Session.new(config)
      initializer = ReplicationInitializer.new(session)
      initializer.ensure_activity_marker_tables
      session.left.tables.include?('rx_active').should be_true
      session.right.tables.include?('rx_active').should be_true
    
      # right columns?
      columns = session.left.columns('rx_active')
      columns.size.should == 1
      columns[0].name.should == 'active'
    ensure
      if session
        session.left.drop_table 'rx_active'
        session.right.drop_table 'rx_active'
      end
    end
  end

  it "ensure_infrastructure should not create the infrastructure tables if they already exist" do
    session = Session.new
    initializer = ReplicationInitializer.new(session)
    session.left.should_not_receive(:create_table)
    initializer.ensure_infrastructure
  end

  it "ensure_infrastructure should create the infrastructure tables" do
    begin
      config = deep_copy(standard_config)
      config.options[:rep_prefix] = 'rx'
      session = Session.new(config)
      initializer = ReplicationInitializer.new(session)
      initializer.should_receive :ensure_activity_marker_tables
      initializer.ensure_infrastructure
      session.left.tables.include?('rx_change_log').should be_true
      session.right.tables.include?('rx_change_log').should be_true
      session.left.tables.include?('rx_event_log').should be_true
    ensure
      if session
        session.left.drop_table 'rx_change_log'
        session.right.drop_table 'rx_change_log'
      end
    end
  end

  it "exclude_ruby_rep_tables should exclude the correct system tables" do
    config = deep_copy(standard_config)
    initializer = ReplicationInitializer.new(Session.new(config))
    initializer.session.configuration.should_receive(:exclude_tables).with(/^rr_.*/)
    initializer.exclude_rubyrep_tables
  end

  it "restore_tables should remove triggers and sequences setups of unconfigured tables" do
    session = Session.new
    initializer = ReplicationInitializer.new session
    begin
      ['scanner_left_records_only', 'scanner_records'].each do |table|
        initializer.create_trigger(:left, table)
        initializer.create_trigger(:right, table)
        initializer.ensure_sequence_setup(
          {:left => table, :right => table},
          2, 0, 1
        )
        session.right.insert_record table, {'id' => 100, 'name' => 'bla'}
      end

      # verify that the unconfigured tables are restored and pending changes deleted
      initializer.restore_unconfigured_tables
      initializer.trigger_exists?(:right, 'scanner_records').should be_false
      session.right.outdated_sequence_values('rr', 'scanner_records', 2, 1).size.should == 1
      session.right.select_one("select * from rr_change_log where change_table = 'scanner_records'").should be_nil

      # verify that the configured tables are not touched
      initializer.trigger_exists?(:right, 'scanner_left_records_only').should be_true
      session.right.outdated_sequence_values('rr', 'scanner_left_records_only', 2, 1).size.should == 0
      session.right.select_one("select * from rr_change_log where change_table = 'scanner_left_records_only'").should_not be_nil
    ensure
      ['scanner_left_records_only', 'scanner_records'].each do |table|
        [:left, :right].each do |database|
          if initializer.trigger_exists?(database, table)
            initializer.drop_trigger(database, table)
          end
          initializer.clear_sequence_setup database, table
        end
        session.right.delete_record table, {'id' => 100}
      end
      session.right.execute "delete from rr_change_log"
    end
  end

  it "prepare_replication should prepare the replication" do
    session = nil
    initializer = nil
    org_stdout = $stdout

    config = deep_copy(standard_config)
    config.options[:committer] = :buffered_commit
    config.options[:use_ansi] = false
    config.include_tables 'rr_change_log' # added to verify that it is ignored

    session = Session.new(config)

    $stdout = StringIO.new
    begin
      initializer = ReplicationInitializer.new(session)
      initializer.should_receive(:ensure_infrastructure).any_number_of_times
      initializer.should_receive(:restore_unconfigured_tables).any_number_of_times
      initializer.prepare_replication
      # verify sequences have been setup
      session.left.outdated_sequence_values('rr','scanner_left_records_only', 2, 0).should == {}
      session.right.outdated_sequence_values('rr','scanner_left_records_only', 2, 1).should == {}

      # verify table was synced
      left_records = session.left.select_all("select * from  scanner_left_records_only order by id")
      right_records = session.left.select_all("select * from  scanner_left_records_only order by id")
      left_records.should == right_records

      # verify rubyrep activity is _not_ logged
      session.right.select_all("select * from rr_change_log").should be_empty

      # verify other data changes are logged
      initializer.trigger_exists?(:left, 'scanner_left_records_only').should be_true
      session.left.insert_record 'scanner_left_records_only', {'id' => 10, 'name' => 'bla'}
      changes = session.left.select_all("select change_key from rr_change_log")
      changes.size.should == 1
      changes[0]['change_key'].should == 'id|10'

      # verify that the 'rr_change_log' table was not touched
      initializer.trigger_exists?(:left, 'rr_change_log').should be_false

      # verify that syncing is done only for unsynced tables
      SyncRunner.should_not_receive(:new)
      initializer.prepare_replication

    ensure
      $stdout = org_stdout
      if session
        session.left.execute "delete from scanner_left_records_only where id = 10"
        session.right.execute "delete from scanner_left_records_only"
        [:left, :right].each do |database|
          session.send(database).execute "delete from rr_change_log"
        end
      end
      if initializer
        [:left, :right].each do |database|
          initializer.clear_sequence_setup database, 'scanner_left_records_only'
          initializer.clear_sequence_setup database, 'table_with_manual_key'
          ['scanner_left_records_only', 'table_with_manual_key'].each do |table|
            if initializer.trigger_exists?(database, table)
              initializer.drop_trigger database, table
            end
          end
        end
      end
    end
  end
end
