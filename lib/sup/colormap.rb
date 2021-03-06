module Curses
  COLOR_DEFAULT = -1
end

module Redwood

class Colormap
  @@instance = nil

  CURSES_COLORS = [Curses::COLOR_BLACK, Curses::COLOR_RED, Curses::COLOR_GREEN,
                   Curses::COLOR_YELLOW, Curses::COLOR_BLUE,
                   Curses::COLOR_MAGENTA, Curses::COLOR_CYAN,
                   Curses::COLOR_WHITE, Curses::COLOR_DEFAULT]
  NUM_COLORS = (CURSES_COLORS.size - 1) * (CURSES_COLORS.size - 1)

  DEFAULT_COLORS = {
    :status => { :fg => "white", :bg => "blue", :attrs => ["bold"] },
    :index_old => { :fg => "white", :bg => "default" },
    :index_new => { :fg => "white", :bg => "default", :attrs => ["bold"] },
    :index_starred => { :fg => "yellow", :bg => "default", :attrs => ["bold"] },
    :index_draft => { :fg => "red", :bg => "default", :attrs => ["bold"] },
    :labellist_old => { :fg => "white", :bg => "default" },
    :labellist_new => { :fg => "white", :bg => "default", :attrs => ["bold"] },
    :twiddle => { :fg => "blue", :bg => "default" },
    :label => { :fg => "yellow", :bg => "default" },
    :message_patina => { :fg => "black", :bg => "green" },
    :alternate_patina => { :fg => "black", :bg => "blue" },
    :missing_message => { :fg => "black", :bg => "red" },
    :attachment => { :fg => "cyan", :bg => "default" },
    :cryptosig_valid => { :fg => "yellow", :bg => "default", :attrs => ["bold"] },
    :cryptosig_unknown => { :fg => "cyan", :bg => "default" },
    :cryptosig_invalid => { :fg => "yellow", :bg => "red", :attrs => ["bold"] },
    :generic_notice_patina => { :fg => "cyan", :bg => "default" },
    :quote_patina => { :fg => "yellow", :bg => "default" },
    :sig_patina => { :fg => "yellow", :bg => "default" },
    :quote => { :fg => "yellow", :bg => "default" },
    :sig => { :fg => "yellow", :bg => "default" },
    :to_me => { :fg => "green", :bg => "default" },
    :starred => { :fg => "yellow", :bg => "default", :attrs => ["bold"] },
    :starred_patina => { :fg => "yellow", :bg => "green", :attrs => ["bold"] },
    :alternate_starred_patina => { :fg => "yellow", :bg => "blue", :attrs => ["bold"] },
    :snippet => { :fg => "cyan", :bg => "default" },
    :option => { :fg => "white", :bg => "default" },
    :tagged => { :fg => "yellow", :bg => "default", :attrs => ["bold"] },
    :draft_notification => { :fg => "red", :bg => "default", :attrs => ["bold"] },
    :completion_character => { :fg => "white", :bg => "default", :attrs => ["bold"] },
    :horizontal_selector_selected => { :fg => "yellow", :bg => "default", :attrs => ["bold"] },
    :horizontal_selector_unselected => { :fg => "cyan", :bg => "default" },
    :search_highlight => { :fg => "black", :bg => "yellow", :attrs => ["bold"] },
    :system_buf => { :fg => "blue", :bg => "default" },
    :regular_buf => { :fg => "white", :bg => "default" },
    :modified_buffer => { :fg => "yellow", :bg => "default", :attrs => ["bold"] },
  }
  
  def initialize
    raise "only one instance can be created" if @@instance
    @@instance = self
    @entries = {}
    @color_pairs = {[Curses::COLOR_WHITE, Curses::COLOR_BLACK] => 0}
    @users = []
    @next_id = 0
    yield self if block_given?
    @entries[highlight_sym(:none)] = highlight_for(Curses::COLOR_WHITE,
                                                   Curses::COLOR_BLACK,
                                                   []) + [nil]
  end

  def add sym, fg, bg, attr=nil, opts={}
    raise ArgumentError, "color for #{sym} already defined" if @entries.member? sym
    raise ArgumentError, "color '#{fg}' unknown" unless CURSES_COLORS.include? fg
    raise ArgumentError, "color '#{bg}' unknown" unless CURSES_COLORS.include? bg
    attrs = [attr].flatten.compact

    @entries[sym] = [fg, bg, attrs, nil]
    @entries[highlight_sym(sym)] = opts[:highlight] ? @entries[opts[:highlight]] : highlight_for(fg, bg, attrs) + [nil]
  end

  def highlight_sym sym
    "#{sym}_highlight".intern
  end

  def highlight_for fg, bg, attrs
    hfg =
      case fg
      when Curses::COLOR_BLUE
        Curses::COLOR_WHITE
      when Curses::COLOR_YELLOW, Curses::COLOR_GREEN
        fg
      else
        Curses::COLOR_BLACK
      end

    hbg = 
      case bg
      when Curses::COLOR_CYAN
        Curses::COLOR_YELLOW
      when Curses::COLOR_YELLOW
        Curses::COLOR_BLUE
      else
        Curses::COLOR_CYAN
      end

    attrs =
      if fg == Curses::COLOR_WHITE && attrs.include?(Curses::A_BOLD)
        [Curses::A_BOLD]
      else
        case hfg
        when Curses::COLOR_BLACK
          []
        else
          [Curses::A_BOLD]
        end
      end
    [hfg, hbg, attrs]
  end

  def color_for sym, highlight=false
    sym = highlight_sym(sym) if highlight
    return Curses::COLOR_BLACK if sym == :none
    raise ArgumentError, "undefined color #{sym}" unless @entries.member? sym

    ## if this color is cached, return it
    fg, bg, attrs, color = @entries[sym]
    return color if color

    if(cp = @color_pairs[[fg, bg]])
      ## nothing
    else ## need to get a new colorpair
      @next_id = (@next_id + 1) % NUM_COLORS
      @next_id += 1 if @next_id == 0 # 0 is always white on black
      id = @next_id
      debug "colormap: for color #{sym}, using id #{id} -> #{fg}, #{bg}"
      Curses.init_pair id, fg, bg or raise ArgumentError,
        "couldn't initialize curses color pair #{fg}, #{bg} (key #{id})"

      cp = @color_pairs[[fg, bg]] = Curses.color_pair(id)
      ## delete the old mapping, if it exists
      if @users[cp]
        @users[cp].each do |usym|
          warn "dropping color #{usym} (#{id})"
          @entries[usym][3] = nil
        end
        @users[cp] = []
      end
    end

    ## by now we have a color pair
    color = attrs.inject(cp) { |color, attr| color | attr }
    @entries[sym][3] = color # fill the cache
    (@users[cp] ||= []) << sym # record entry as a user of that color pair
    color
  end

  ## Try to use the user defined colors, in case of an error fall back
  ## to the default ones.
  def populate_colormap
    user_colors = if File.exists? Redwood::COLOR_FN
      debug "loading user colors from #{Redwood::COLOR_FN}"
      Redwood::load_yaml_obj Redwood::COLOR_FN
    end

    error = nil
    Colormap::DEFAULT_COLORS.each_pair do |k, v|
      fg = Curses.const_get "COLOR_#{v[:fg].upcase}"
      bg = Curses.const_get "COLOR_#{v[:bg].upcase}"
      attrs = v[:attrs] ? v[:attrs].map { |a| Curses.const_get "A_#{a.upcase}" } : []

      if user_colors && (ucolor = user_colors[k])
        if(ufg = ucolor[:fg])
          begin
            fg = Curses.const_get "COLOR_#{ufg.upcase}"
          rescue NameError
            error ||= "Warning: there is no color named \"#{ufg}\", using fallback."
            warn "there is no color named \"#{ufg}\""
          end
        end

        if(ubg = ucolor[:bg])
          begin
            bg = Curses.const_get "COLOR_#{ubg.upcase}"
          rescue NameError
            error ||= "Warning: there is no color named \"#{ubg}\", using fallback."
            warn "there is no color named \"#{ubg}\""
          end
        end

        if(uattrs = ucolor[:attrs])
          attrs = [*uattrs].flatten.map do |a|
            begin
              Curses.const_get "A_#{a.upcase}"
            rescue NameError
              error ||= "Warning: there is no attribute named \"#{a}\", using fallback."
              warn "there is no attribute named \"#{a}\", using fallback."
            end
          end
        end
      end

      symbol = (k.to_s + "_color").to_sym
      add symbol, fg, bg, attrs
    end

    BufferManager.flash error if error
  end

  def self.instance; @@instance; end
  def self.method_missing meth, *a
    Colormap.new unless @@instance
    @@instance.send meth, *a
  end
end

end
