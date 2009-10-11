module Redwood

## Implements a single undo list for the Sup instance

class UndoManager
  include Singleton

  class UndoAction
    attr_reader :desc, :entries

    def initialize desc
      @desc = desc
      @entries = []
    end

    def add msgid, old_labels
      @entries << [msgid, old_labels]
    end
  end

  def initialize
    @stack = []
  end

  def register desc=nil
    action = UndoAction.new(desc)
    yield action
    @stack.push action
  end

  def undo
    unless action = @stack.pop
      BufferManager.flash "nothing more to undo!"
      return
    end

    action.entries.each do |msgid, old_labels|
      m = Index.build_message msgid
      m.labels = old_labels
      m.save_state_async(Index)
    end

    desc = action.desc || "modifications of #{action.entries.size} messages"
    BufferManager.flash "undid #{desc}"
  end
end
end
