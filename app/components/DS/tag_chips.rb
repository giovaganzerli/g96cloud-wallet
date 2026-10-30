class DS::TagChips < DesignSystemComponent
  attr_reader :form, :tags

  def initialize(form:, tags:)
    @form = form
    @tags = tags
  end
end
