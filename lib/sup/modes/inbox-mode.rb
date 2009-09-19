require 'sup'

module Redwood

class InboxMode < ThreadIndexMode
  register_keymap do |k|
    ## overwrite toggle_archived with archive
    k.add :archive, "Archive thread (remove from inbox)", 'a'
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

  def archive
    return unless thread = cursor_thread
    thread.remove_label :inbox
    save_thread_state thread
    regen_text
  end

  def multi_archive threads
    threads.each do |t|
      t.remove_label :inbox
      save_thread_state t
    end
    regen_text
  end

  def read_and_archive
    return unless thread = cursor_thread
    thread.remove_label :unread
    thread.remove_label :inbox
    save_thread_state thread
    regen_text
  end

  def multi_read_and_archive threads
    old_labels = threads.map { |t| t.labels.dup }

    threads.each do |t|
      t.remove_label :unread
      t.remove_label :inbox
      save_thread_state t
    end
    regen_text
  end

  def handle_unarchived_update sender, m
    add_or_unhide m
  end

  def handle_archived_update sender, m
    t = thread_containing(m) or return
    regen_text
  end

  def status
    super + "    #{Index.size} messages in index"
  end
end

end
