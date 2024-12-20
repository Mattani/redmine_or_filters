module QueriesHelperPatch
  def filters_options_for_select(query)
    ungrouped = []
    grouped = {label_string: [], label_date: [], label_time_tracking: [], label_attachment: []}
    query.available_filters.map do |field, field_options|
      if /^cf_\d+\./.match?(field)
        group = (field_options[:through] || field_options[:field]).try(:name)
      elsif field =~ /^(.+)\./
        # association filters
        group = "field_#{$1}".to_sym
      elsif field_options[:type] == :relation
        group = :label_relations
      elsif field_options[:type] == :tree
        group = query.is_a?(IssueQuery) ? :label_relations : nil
      elsif %w(member_of_group assigned_to_role).include?(field)
        group = :field_assigned_to
      elsif field_options[:type] == :date_past || field_options[:type] == :date
        group = :label_date
      elsif %w(estimated_hours spent_time).include?(field)
        group = :label_time_tracking
      elsif %w(attachment attachment_description).include?(field)
        group = :label_attachment
      elsif field_options[:group] == 'or_filter'
        group = :label_orfilter
      elsif [:string, :text, :search].include?(field_options[:type])
        group = :label_string
      end
      if group
        (grouped[group] ||= []) << [field_options[:name], field]
      else
        ungrouped << [field_options[:name], field]
      end
    end
    # Remove empty groups
    grouped.delete_if {|k, v| v.empty?}
    # Don't group dates if there's only one (eg. time entries filters)
    if grouped[:label_date].try(:size) == 1
      ungrouped << grouped.delete(:label_date).first
    end
    s = options_for_select([[]] + ungrouped)
    if grouped.present?
      localized_grouped = grouped.map {|k, v| [k.is_a?(Symbol) ? l(k) : k.to_s, v]}
      s << grouped_options_for_select(localized_grouped)
    end
    s
  end
end

QueriesHelper.send(:prepend, QueriesHelperPatch)