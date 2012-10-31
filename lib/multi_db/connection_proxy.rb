require 'tlattr_accessors'
require 'active_record/connection_adapters/abstract/query_cache'

module MultiDb
  class ConnectionProxy
    include QueryCacheCompat
    include ActiveRecord::ConnectionAdapters::QueryCache
    extend ThreadLocalAccessors

    # Safe methods are those that should either go to the slave ONLY or go
    # to the current active connection.
    SAFE_METHODS = %w(
      select_all select_one select_value select_values select_rows select
      verify! raw_connection active? reconnect!  disconnect! reset_runtime log
      log_info table_exists?  sanitize_limit quote_table_name ids_in_list_limit
      quote quote_column_name prefetch_primary_key?
      case_sensitive_equality_operator table_alias_for columns indexes
    ).inject({}) { |acc, val|
      acc[val.to_sym]=true
      acc
    }.freeze

    # Methods that don't communicate with the database server and don't use and
    # hidden state that may vary between connections.
    IGNORABLE_METHODS = %w(
      log log_info sanitize_limit quote_table_name quote quote_column_name
      prefetch_primary_key?  case_sensitive_equality_operator table_alias_for
    ).inject({}) { |acc, val|
      acc[val.to_sym] = true
      acc
    }.freeze

    RECONNECT_EXCEPTIONS = [ActiveRecord::ConnectionNotEstablished]

    attr_accessor :master
    tlattr_accessor :master_depth, :current, true

    def initialize(master, slaves, scheduler = Scheduler)
      @scheduler = scheduler.new(slaves)
      @master    = master
      @reconnect = false
      @query_cache = {}

      self.current = @master
      self.master_depth = 1
    end

    def with_master
      self.current = @master
      self.master_depth += 1
      yield
    ensure
      self.master_depth -= 1
      self.current = slave if (master_depth <= 0)
    end

    def with_slave
      self.current = slave
      self.master_depth -= 1
      yield
    ensure
      self.master_depth += 1
      self.current = @master if (master_depth > 0)
    end

    def transaction(start_db_transaction = true, &block)
      with_master { @master.retrieve_connection.transaction(start_db_transaction, &block) }
    end

    # Calls the method on master/slave and dynamically creates a new
    # method on success to speed up subsequent calls
    def method_missing(method, *args, &block)
      send(target_method(method), method, *args, &block).tap do
        create_delegation_method!(method)
      end
    end

    # Switches to the next slave database for read operations.
    # Fails over to the master database if all slaves are unavailable.
    def next_reader!
      return if  master_depth > 0  # don't if in with_master block
      self.current = @scheduler.next
    rescue Scheduler::NoMoreItems
      logger.warn "[MULTIDB] All slaves are blacklisted. Reading from master"
      self.current = @master
    end

    protected

    def create_delegation_method!(method)
      target = target_method(method)
      self.class.send(:define_method, method) { |*args, &block|
        send(target, method, *args, &block)
      }
    end

    def target_method(method)
      unsafe?(method) ? :send_to_master : :send_to_current
    end

    def send_to_master(method, *args, &block)
      mark_sticky(method, args[0]) if unsafe?(method)
      with_master { perform_query(method, *args, &block) }
    end

    def send_to_current(method, *args, &block)
      if needs_sticky_master?(method, args[0])
        send_to_master(method, *args, &block)
      else
        perform_query(method, *args, &block)
      end
    end

    def perform_query(method, *args, &block)
      if master?
        @reconnect and reconnect_master!
      else
        find_up_to_date_reader!
      end

      record_statistic(current.name) unless IGNORABLE_METHODS[method]

      connection = Rails.env.test? ? @master : current
      connection.retrieve_connection.send(method, *args, &block)
    rescue *RECONNECT_EXCEPTIONS, ActiveRecord::StatementInvalid => e
      raise if ActiveRecord::StatementInvalid === e && e.message !~ /server has gone away/

      raise_master_error(e) if master?
      logger.warn "[MULTIDB] Error reading from slave database"
      logger.error %(#{e.message}\n#{e.backtrace.join("\n")})
      @scheduler.blacklist!(current)
      next_reader!
      retry
    end

    def find_up_to_date_reader!
      # This will, as a worst case, terminate when we give up on
      # slaves and set current to master, since master always has
      # replica lag of 0.
      while LagMonitor.replication_lag_too_high?(current)
        @scheduler.blacklist!(current)
        next_reader!
      end
    end

    def record_statistic(connection_name)
      # hook method
    end

    def mark_sticky(method, sql)
      return if noncommunicating_method?(method, sql)
      duration = LagMonitor.sticky_master_duration(slave)
      QueryAnalyzer.mark_sticky_tables_in_session(Session.current_session, sql, duration)
    end

    def needs_sticky_master?(method, sql)
      return false if noncommunicating_method?(method, sql)
      QueryAnalyzer.query_requires_sticky?(Session.current_session, sql)
    end

    NONCOMMUNICATING_MASTER_METHODS = [:open_transactions, :add_transaction_record]
    def noncommunicating_method?(method, sql)
      return true if NONCOMMUNICATING_MASTER_METHODS.include?(method)
      # If the second param is not a string, it does not send a query.
      !(String === sql)
    end

    def reconnect_master!
      @master.retrieve_connection.reconnect!
      @reconnect = false
    end

    def raise_master_error(error)
      logger.fatal "[MULTIDB] Error accessing master database. Scheduling reconnect"
      @reconnect = true
      raise error
    end

    def unsafe?(method)
      !SAFE_METHODS[method]
    end

    def master?
      current == @master
    end

    def logger
      ActiveRecord::Base.logger
    end

    def slave
      @scheduler.current
    end

  end
end

