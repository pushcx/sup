module Redwood

## Classic listener/broadcaster paradigm. Handles communication between various
## parts of Sup.
##
## Usage note: don't pass threads around. Neither thread nor message equality is
## defined anywhere in Sup beyond standard object equality. To communicate
## something about a particular thread, just pass a representative message from
## it around.
##
## (This assumes that no message will be a part of more than one thread within a
## single "view". Luckily, that's true.)

class UpdateManager
  include Singleton

  def initialize
    @targets = {}
    @queue = []
    @lock = Mutex.new
  end

  def register o; @targets[o] = true; end
  def unregister o; @targets.delete o; end

  def enqueue sender, type, *args
    @lock.synchronize { @queue << [sender, type, args] }
    Ncurses.post_event if defined? Ncurses
  end

  def dequeue_all
    until @queue.empty?
      old_queue = @lock.synchronize do
        returning(@queue) { @queue = [] }
      end

      old_queue.each do |sender, type, args|
        relay sender, type, *args
      end
    end
  end

  def relay sender, type, *args
    meth = "handle_#{type}_update".intern
    @targets.keys.each { |o| o.send meth, sender, *args unless o == sender if o.respond_to? meth }
  end
end

end
