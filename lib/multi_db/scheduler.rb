require 'tlattr_accessors'
require 'speedytime'
require 'active_support/core_ext/module/delegation'

module MultiDb
  class Scheduler
    NoMoreItems = Class.new(Exception)
    extend ThreadLocalAccessors

    attr :items
    delegate :[], :[]=, to: :items
    tlattr_accessor :current_index, true

    def initialize(items, blacklist_timeout = 30)
      @n = items.length
      @items     = items
      reset_blacklist
      @blacklist_timeout = blacklist_timeout
      self.current_index = proc{rand(@n)}
    end

    def blacklist!(item)
      index = @items.index(item)
      @blacklist[index] = Speedytime.current if index
    end

    def reset_blacklist
      @blacklist = Array.new(@n, 0)
    end

    def current
      @items[current_index_i]
    end

    def current_index_i
      index = current_index
      if Proc === index
        self.current_index = index.call
      else
        index
      end
    end

    def next
      previous = current_index_i
      threshold = Speedytime.current - @blacklist_timeout
      until(@blacklist[next_index!] < threshold) do
        raise NoMoreItems, 'All items are blacklisted' if current_index == previous
      end
      current
    end

    protected

    def next_index!
      self.current_index = (current_index + 1) % @n
    end

  end
end
