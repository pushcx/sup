require 'sup'

module Redwood

class InboxMode < ThreadIndexMode
  register_keymap do |k|
    k.add :read_and_archive, "Archive thread (remove from inbox) and mark read", 'A'
  end

  def initialize
    super [:inbox, :sent, :draft], { :label => :inbox, :skip_killed => true }
    raise "can't have more than one!" if defined? @@instance
    @@instance = self
  end

  ## label-list-mode wants to be able to raise us if the user selects
  ## the "inbox" label, so we need to keep our singletonness around
  def self.instance; @@instance; end
  def killable?; false; end

  def read_and_archive
    return unless t = cursor_thread
    remove_thread_label t, :unread
    remove_thread_label t, :inbox
    cursor_down
  end

  def multi_read_and_archive threads
    threads.each do |t|
      remove_thread_label t, :unread
      remove_thread_label t, :inbox
    end
  end

  def status
    super + "    #{Index.size} messages in index"
  end
end

end
