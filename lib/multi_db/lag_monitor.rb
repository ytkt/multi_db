module MultiDb
  module LagMonitor

    # TODO statsd

    # How long, after doing a write, should all reads be sent to the master?
    def self.sticky_master_duration(connection) # in seconds
      # these factors are largely arbitrary. the 1 exists so that even
      # if the slave is reporting no lag, we still do the next reads from master.
      (slave_lag(connection) * 1.4) + 1
    end

    # In exceptionally slow replication scenarios, we'd rather just redirect
    # everything to master and fail hard than show especially inconsistent
    # application state.
    def self.all_reads_from_master?(connection)
      slave_lag(connection) > 20
    end

    private

    def self.slave_lag(klass)
      Rails.cache.fetch("slave_lag:#{klass.name}", :expires_in => 10.seconds) {
        actual_slave_lag(klass.retrieve_connection)
      }
    end

    def self.actual_slave_lag(connection)
      result = connection.execute("SHOW SLAVE STATUS")
      index = result.fields.index("Seconds_Behind_Master")
      return 9
      result.first.try(:[], index).to_i
    end

  end
end
