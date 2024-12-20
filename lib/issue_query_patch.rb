module IssueQueryPatch

  def initialize_available_filters
    super
      add_available_filter "and_any",
                           :name => l(:label_orfilter_and_any),
                           :type => :list,
                           :values => [l(:general_text_Yes)],
                           :group => 'or_filter'
      add_available_filter "or_any",
                           :name => l(:label_orfilter_or_any),
                           :type => :list,
                           :values => [l(:general_text_Yes)],
                           :group => 'or_filter'
      add_available_filter "or_all",
                           :name => l(:label_orfilter_or_all),
                           :type => :list,
                           :values => [l(:general_text_Yes)],
                           :group => 'or_filter'
  end
end

IssueQuery.send(:prepend, IssueQueryPatch)