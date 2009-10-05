require 'set'

module Redwood

class ThreadIndexMode < LineCursorMode
  DATE_WIDTH = Time::TO_NICE_S_MAX_LEN
  MIN_FROM_WIDTH = 15
  LOAD_MORE_THREAD_NUM = 20

  HookManager.register "index-mode-size-widget", <<EOS
Generates the per-thread size widget for each thread.
Variables:
  thread: The message thread to be formatted.
EOS

  HookManager.register "mark-as-spam", <<EOS
This hook is run when a thread is marked as spam
Variables:
  thread: The message thread being marked as spam.
EOS

  register_keymap do |k|
    k.add :load_threads, "Load #{LOAD_MORE_THREAD_NUM} more threads", 'M'
    k.add_multi "Load all threads (! to confirm) :", '!' do |kk|
      kk.add :load_all_threads, "Load all threads (may list a _lot_ of threads)", '!'
    end
    k.add :cancel_search, "Cancel current search", :ctrl_g
    k.add :reload, "Refresh view", '@'
    k.add :toggle_archived, "Toggle archived status", 'a'
    k.add :toggle_starred, "Star or unstar all messages in thread", '*'
    k.add :toggle_new, "Toggle new/read status of all messages in thread", 'N'
    k.add :edit_labels, "Edit or add labels for a thread", 'l'
    k.add :edit_message, "Edit message (drafts only)", 'e'
    k.add :toggle_spam, "Mark/unmark thread as spam", 'S'
    k.add :toggle_deleted, "Delete/undelete thread", 'd'
    k.add :kill, "Kill thread (never to be seen in inbox again)", '&'
    k.add :jump_to_next_new, "Jump to next new thread", :tab
    k.add :reply, "Reply to latest message in a thread", 'r'
    k.add :reply_all, "Reply to all participants of the latest message in a thread", 'G'
    k.add :forward, "Forward latest message in a thread", 'f'
    k.add :toggle_tagged, "Tag/untag selected thread", 't'
    k.add :toggle_tagged_all, "Tag/untag all threads", 'T'
    k.add :tag_matching, "Tag matching threads", 'g'
    k.add :apply_to_tagged, "Apply next command to all tagged threads", '+', '='
    k.add :join_threads, "Force tagged threads to be joined into the same thread", '#'
    k.add :undo, "Undo the previous action", 'u'
    k.add :drop_irrelevant, "Remove irrelevant threads", '%'
  end

  def initialize hidden_labels=[], load_thread_opts={}
    super()
    @mutex = Mutex.new # covers the following variables:
    @threads = {}
    @size_widget_width = 5
    @tags = Tagger.new self
    @text_for_threads = SavingHash.new { |t| generate_text_for_thread t }

    ## these guys, and @text and @lines, are not covered
    @load_thread = nil
    @hidden_labels = hidden_labels + LabelManager::HIDDEN_RESERVED_LABELS
    @date_width = DATE_WIDTH

    @interrupt_search = false
    
    initialize_threads load_thread_opts # defines @ts
    update # defines @text and @lines

    @last_load_more_size = nil
    to_load_more do |size|
      next if @last_load_more_size == 0
      load_threads :num => size,
                   :when_done => lambda { |num| @last_load_more_size = num }
    end

    UpdateManager.register self
  end

  def save_thread_state t
    t.save_state_async Index
  end

  def lines; @text.length; end
  def [] i; @text[i]; end
  def contains_thread? t; @threads.include?(t) end

  def reload
    drop_all_threads
    BufferManager.draw_screen
    load_threads :num => buffer.content_height
  end

  def drop_irrelevant
    @mutex.synchronize do
      @ts.drop_irrelevant
    end
    update
  end

  ## open up a thread view window
  def select t=nil, when_done=nil
    t ||= cursor_thread or return

    Redwood::reporting_thread("load messages for thread-view-mode") do
      num = t.size
      message = "Loading #{num.pluralize 'message body'}..."
      BufferManager.say(message) do |sid|
        t.each_with_index do |(m, *o), i|
          next unless m
          BufferManager.say "#{message} (#{i}/#{num})", sid if t.size > 1
          m.load_from_source! 
        end
      end
      mode = ThreadViewMode.new t, @hidden_labels, self
      BufferManager.spawn t.subj, mode
      BufferManager.draw_screen
      mode.jump_to_first_open
      BufferManager.draw_screen # lame TODO: make this unnecessary
      ## the first draw_screen is needed before topline and botline
      ## are set, and the second to show the cursor having moved

      update_thread t
      when_done.call if when_done
    end
  end

  def multi_select threads
    threads.each { |t| select t }
  end

  ## these two methods are called by thread-view-modes when the user
  ## wants to view the previous/next thread without going back to
  ## index-mode. we update the cursor as a convenience.
  def launch_next_thread_after thread, &b
    launch_another_thread thread, 1, &b
  end

  def launch_prev_thread_before thread, &b
    launch_another_thread thread, -1, &b
  end

  def launch_another_thread thread, direction, &b
    l = @lines[thread] or return
    target_l = l + direction
    t = @mutex.synchronize do
      if target_l >= 0 && target_l < @threads.length
        @threads[target_l]
      end
    end

    if t # there's a next thread
      set_cursor_pos target_l # move out of mutex?
      select t, b
    elsif b # no next thread. call the block anyways
      b.call
    end
  end

  def handle_thread_update sender, t
    return unless sender == @ts
    update_thread @last_t if @last_t && t != @last_t
    @last_t = t
  end

  def handle_tick_update sender
    handle_thread_update @ts, nil
  end

  def undo
    unimplemented
  end

  def add_thread_label thread, label
    thread.first.add_label label # add only to first
    update_thread thread
    save_thread_state thread
  end

  def apply_thread_label thread, label
    LabelManager << label
    thread.apply_label label
    update_thread thread
    save_thread_state thread
  end

  def set_thread_labels thread, labels
    labels.each { |label| LabelManager << label }
    thread.labels = labels
    update_thread thread
    save_thread_state thread
  end

  def remove_thread_label thread, label
    thread.remove_label label # remove from all
    update_thread thread
    save_thread_state thread
  end

  def edit_message
    return unless(t = cursor_thread)
    message, *crap = t.find { |m, *o| m.has_label? :draft }
    if message
      mode = ResumeMode.new message
      BufferManager.spawn "Edit message", mode
    else
      BufferManager.flash "Not a draft message!"
    end
  end

  def actually_toggle_label thread, label, shallow
    if thread.has_label? label
      remove_thread_label thread, label
    elsif shallow
      add_thread_label thread, label
    else
      apply_thread_label thread, label
    end
  end

  def toggle_starred 
    t = cursor_thread or return
    actually_toggle_label t, :starred, true
    cursor_down
  end

  def multi_toggle_starred threads
    threads.each { |t| actually_toggle_label t, :starred, true }
  end

  def toggle_archived 
    t = cursor_thread or return
    actually_toggle_label t, :inbox, false
    cursor_down
  end

  def multi_toggle_archived threads
    threads.each { |t| actually_toggle_label t, :inbox, false }
  end

  def toggle_new
    t = cursor_thread or return
    actually_toggle_label t, :unread, false
    cursor_down
  end

  def multi_toggle_new threads
    threads.each { |t| actually_toggle_label t, :unread, false }
  end

  def multi_toggle_tagged threads
    @mutex.synchronize { @tags.drop_all_tags }
    regen_text #XXX
  end

  def join_threads
    ## this command has no non-tagged form. as a convenience, allow this
    ## command to be applied to tagged threads without hitting ';'.
    @tags.apply_to_tagged :join_threads
  end

  def multi_join_threads threads
    @ts.join_threads threads or return
    @tags.drop_all_tags # otherwise we have tag pointers to invalid threads!
    update
  end

  def jump_to_next_new
    n = @mutex.synchronize do
      ((curpos + 1) ... lines).find { |i| @threads[i].has_label? :unread } ||
        (0 ... curpos).find { |i| @threads[i].has_label? :unread }
    end
    if n
      ## jump there if necessary
      jump_to_line n unless n >= topline && n < botline
      set_cursor_pos n
    else
      BufferManager.flash "No new messages"
    end
  end

  def toggle_spam
    t = cursor_thread or return
    multi_toggle_spam [t]
    HookManager.run("mark-as-spam", :thread => t)
  end

  def multi_toggle_spam threads
    threads.each { |t| actually_toggle_label t, :spam, false }
  end

  def toggle_deleted
    t = cursor_thread or return
    multi_toggle_deleted [t]
  end

  def multi_toggle_deleted threads
    threads.each { |t| actually_toggle_label t, :deleted, false }
  end

  def kill
    t = cursor_thread or return
    multi_kill [t]
  end

  ## m-m-m-m-MULTI-KILL
  def multi_kill threads
    threads.each { |t| actually_toggle_label t, :killed, false }
    BufferManager.flash "#{threads.size.pluralize 'thread'} killed."
  end

  def edit_labels
    thread = cursor_thread or return
    speciall = (@hidden_labels + LabelManager::RESERVED_LABELS).uniq

    old_labels = thread.labels
    pos = curpos

    keepl, modifyl = thread.labels.partition { |t| speciall.member? t }

    user_labels = BufferManager.ask_for_labels :label, "Labels for thread: ", modifyl, @hidden_labels
    return unless user_labels

    new_labels = Set.new(keepl) + user_labels
    set_thread_labels thread, new_labels
  end

  def multi_edit_labels threads
    user_labels = BufferManager.ask_for_labels :labels, "Add/remove labels (use -label to remove): ", [], @hidden_labels
    return unless user_labels

    user_labels.map! { |l| (l.to_s =~ /^-/)? [l.to_s.gsub(/^-?/, '').to_sym, true] : [l, false] }
    hl = user_labels.select { |(l,_)| @hidden_labels.member? l }
    unless hl.empty?
      BufferManager.flash "'#{hl}' is a reserved label!"
      return
    end

    old_labels = threads.map { |t| t.labels.dup }

    threads.each do |t|
      user_labels.each do |(l, to_remove)|
        # XXX inefficient
        if to_remove
          remove_thread_label t, l
        else
          apply_thread_label t, l
        end
      end
    end
  end

  def cleanup
    @ts.cleanup
    UpdateManager.unregister self

    if @load_thread
      @load_thread.kill 
      BufferManager.clear @mbid if @mbid
      sleep 0.1 # TODO: necessary?
      BufferManager.erase_flash
    end

    dirty_threads = @mutex.synchronize { @threads.select { |t| t.dirty? } }
    fail "#{dirty_threads.size} threads dirty" unless dirty_threads.empty?

    super
  end

  def toggle_tagged
    t = cursor_thread or return
    @mutex.synchronize { @tags.toggle_tag_for t }
    update_thread t
    cursor_down
  end
  
  def toggle_tagged_all
    @mutex.synchronize { @threads.each { |t| @tags.toggle_tag_for t } }
    regen_text
  end

  def tag_matching
    query = BufferManager.ask :search, "tag threads matching (regex): "
    return if query.nil? || query.empty?
    query = begin
      /#{query}/i
    rescue RegexpError => e
      BufferManager.flash "error interpreting '#{query}': #{e.message}"
      return
    end
    @mutex.synchronize { @threads.each { |t| @tags.tag t if thread_matches?(t, query) } }
    regen_text
  end

  def apply_to_tagged; @tags.apply_to_tagged; end

  def reply type_arg=nil
    t = cursor_thread or return
    m = t.latest_message
    return if m.nil? # probably won't happen
    m.load_from_source!
    mode = ReplyMode.new m, type_arg
    BufferManager.spawn "Reply to #{m.subj}", mode
  end

  def reply_all; reply :all; end

  def forward
    t = cursor_thread or return
    m = t.latest_message
    return if m.nil? # probably won't happen
    m.load_from_source!
    ForwardMode.spawn_nicely :message => m
  end

  def load_n_threads_background n=LOAD_MORE_THREAD_NUM, opts={}
    return if @load_thread # todo: wrap in mutex
    @load_thread = Redwood::reporting_thread("load threads for thread-index-mode") do
      num = load_n_threads n, opts
      opts[:when_done].call(num) if opts[:when_done]
      @load_thread = nil
    end
  end

  def load_n_threads n=LOAD_MORE_THREAD_NUM, opts={}
    @interrupt_search = false
    @mbid = BufferManager.say "Searching for threads..."

    ts_to_load = n
    ts_to_load = ts_to_load + @ts.size unless n == -1 # -1 means all threads

    orig_size = @ts.size
    last_update = Time.now
    @ts.load_n_threads(ts_to_load, opts) do |i|
      if (Time.now - last_update) >= 0.25
        BufferManager.say "Loaded #{i.pluralize 'thread'}...", @mbid
        update
        BufferManager.draw_screen
        last_update = Time.now
      end
      ::Thread.pass
      break if @interrupt_search
    end
    @ts.threads.each { |th| th.labels.each { |l| LabelManager << l } }

    update
    BufferManager.clear @mbid
    @mbid = nil
    BufferManager.draw_screen
    @ts.size - orig_size
  end
  ignore_concurrent_calls :load_n_threads

  def status
    if (l = lines) == 0
      "line 0 of 0"
    else
      "line #{curpos + 1} of #{l}"
    end
  end

  def cancel_search
    @interrupt_search = true
  end

  def load_all_threads
    load_threads :num => -1
  end

  def load_threads opts={}
    if opts[:num].nil?
      n = ThreadIndexMode::LOAD_MORE_THREAD_NUM
    else
      n = opts[:num]
    end

    myopts = { :when_done => (lambda do |num|
      opts[:when_done].call(num) if opts[:when_done]

      if num > 0
        BufferManager.flash "Found #{num.pluralize 'thread'}."
      else
        BufferManager.flash "No matches."
      end
    end)}

    if opts[:background] || opts[:background].nil?
      load_n_threads_background n, myopts
    else
      load_n_threads n, myopts
    end
  end
  ignore_concurrent_calls :load_threads

  def resize rows, cols
    regen_text
    super
  end

protected

  ## used to tag threads by query. this can be made a lot more sophisticated,
  ## but for right now we'll do the obvious this.
  def thread_matches? t, query
    t.subj =~ query || t.snippet =~ query || t.participants.any? { |x| x.longname =~ query }
  end

  def size_widget_for_thread t
    HookManager.run("index-mode-size-widget", :thread => t) || default_size_widget_for(t)
  end

  def cursor_thread; @mutex.synchronize { @threads[curpos] }; end

  def drop_all_threads
    @tags.drop_all_tags
    @ts.clear
    update
  end

  # TODO remove irrelevant threads
  def update_thread t
    debug "updating thread #{t}"
    invalidate_text_for_thread t
    if @threads.member? t
      if @ts.is_thread_relevant? t
        line = @lines[t] or fail
        @text[line] = @text_for_threads[t]
        buffer.mark_dirty if buffer
      else
        # XXX optimize
        # @mutex.synchronize { @ts.drop_irrelevant }
        update
      end
    else
      # XXX optimize
      update
    end
  end

  def update
    @mutex.synchronize do
      ## let's see you do THIS in python
      @threads = @ts.threads.sort_by { |t| [t.date, t.first.id] }.reverse
    end

    regen_text
  end

  def regen_text
    @text_for_threads.clear
    threads = @mutex.synchronize { @threads }
    @text = threads.map_with_index { |t, i| text_for_thread_at i }
    @lines = threads.map_with_index { |t, i| [t, i] }.to_h
    buffer.mark_dirty if buffer
  end

  def authors; map { |m, *o| m.from if m }.compact.uniq; end

  ## preserve author order from the thread
  def author_names_and_newness_for_thread t, limit=nil
    new = {}
    seen = {}
    authors = t.map do |m, *o|
      next unless m && m.from
      new[m.from] ||= m.has_label?(:unread)
      next if seen[m.from]
      seen[m.from] = true
      m.from
    end.compact

    result = []
    authors.each do |a|
      break if limit && result.size >= limit
      name = if AccountManager.is_account?(a)
        "me"
      elsif t.authors.size == 1
        a.mediumname
      else
        a.shortname
      end

      result << [name, new[a]]
    end

    result
  end

  AUTHOR_LIMIT = 5
  def generate_text_for_thread t
    fail "thread is nil" unless t
    size_widget = size_widget_for_thread t
    date = t.date.to_nice_s

    starred = t.has_label? :starred

    ## format the from column
    cur_width = 0
    ann = author_names_and_newness_for_thread t, AUTHOR_LIMIT
    from = []
    ann.each_with_index do |(name, newness), i|
      break if cur_width >= from_width
      last = i == ann.length - 1

      abbrev =
        if cur_width + name.display_length > from_width
          name[0 ... (from_width - cur_width - 1)] + "."
        elsif cur_width + name.display_length == from_width
          name[0 ... (from_width - cur_width)]
        else
          if last
            name[0 ... (from_width - cur_width)]
          else
            name[0 ... (from_width - cur_width - 1)] + "," 
          end
        end

      cur_width += abbrev.display_length

      if last && from_width > cur_width
        abbrev += " " * (from_width - cur_width)
      end

      from << [(newness ? :index_new_color : (starred ? :index_starred_color : :index_old_color)), abbrev]
    end

    dp = t.direct_participants.any? { |p| AccountManager.is_account? p }
    p = dp || t.participants.any? { |p| AccountManager.is_account? p }

    subj_color =
      if t.has_label?(:draft)
        :index_draft_color
      elsif t.has_label?(:unread)
        :index_new_color
      elsif starred
        :index_starred_color
      else 
        :index_old_color
      end

    snippet = t.snippet + (t.snippet.empty? ? "" : "...")

    size_widget_text = sprintf "%#{ @size_widget_width}s", size_widget

    [ 
      [:tagged_color, @tags.tagged?(t) ? ">" : " "],
      [:none, sprintf("%#{@date_width}s", date)],
      (starred ? [:starred_color, "*"] : [:none, " "]),
    ] +
      from +
      [
      [subj_color, size_widget_text],
      [:to_me_color, t.labels.member?(:attachment) ? "@" : " "],
      [:irrelevant_color, !@ts.is_thread_relevant?(t) ? "x" : " "],
      [:to_me_color, dp ? ">" : (p ? '+' : " ")],
    ] +
      (t.labels - @hidden_labels).map { |label| [:label_color, "#{label} "] } +
      [
      [subj_color, t.subj + (t.subj.empty? ? "" : " ")],
      [:snippet_color, snippet],
    ]
  end

  def invalidate_text_for_thread t
    @text_for_threads.delete t
  end

  def text_for_thread_at line
    t = @mutex.synchronize { @threads[line] }
    (debug "t is nil at line #{line}"; return) unless t
    @text_for_threads[t]
  end

private

  def default_size_widget_for t
    case t.size
    when 1
      ""
    else
      "(#{t.size})"
    end
  end

  def from_width
    [(buffer.content_width.to_f * 0.2).to_i, MIN_FROM_WIDTH].max
  end

  def initialize_threads load_thread_opts
    @ts = ThreadSet.new Index.instance, load_thread_opts
  end
end

end
