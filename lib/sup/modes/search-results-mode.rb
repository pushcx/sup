module Redwood

class SearchResultsMode < ThreadIndexMode
  def initialize query
    @query = query
    super [], query
  end

  register_keymap do |k|
    k.add :refine_search, "Refine search", '|'
  end

  def refine_search
    text = BufferManager.ask :search, "refine query: ", (@query[:text] + " ")
    return unless text && text !~ /^\s*$/
    SearchResultsMode.spawn_from_query text
  end

  def self.spawn_from_query text
    begin
      query = Index.parse_query(text)
      return unless query
      short_text = text.length < 20 ? text : text[0 ... 20] + "..."
      mode = SearchResultsMode.new query
      BufferManager.spawn "search: \"#{short_text}\"", mode
      mode.load_threads :num => mode.buffer.content_height
    rescue Index::ParseError => e
      BufferManager.flash "Problem: #{e.message}!"
    end
  end
end

end
