module Redwood

class PersonSearchResultsMode < ThreadIndexMode
  def initialize people
    super [], { :participants => people }
  end
end

end
