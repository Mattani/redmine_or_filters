module QueryPatch

  def statement
    # filters clauses
    filters_clauses = []

        and_clauses=[]
        and_any_clauses=[]
        or_any_clauses=[]
        or_all_clauses=[]
        and_any_op = ""
        or_any_op = ""
        or_all_op = ""

        #the AND filter start first
        filters_clauses = and_clauses

    filters.each_key do |field|
      next if field == "subproject_id"

      if field == "and_any"
        # start the and any part, point filters_clause to and_any_clauses
        filters_clauses = and_any_clauses
        and_any_op = operator_for(field) == "=" ? " AND " : " AND NOT "
        next
      elsif field == "or_any"
        # start the or any part, point filters_clause to or_any_clauses
        filters_clauses = or_any_clauses
        or_any_op = operator_for(field) == "=" ? " OR " : " OR NOT "
        next
      elsif field == "or_all"
        # start the or any part, point filters_clause to or_any_clauses
        filters_clauses = or_all_clauses
        or_all_op = operator_for(field) == "=" ? " OR " : " OR NOT "
        next
      end

      v = values_for(field).clone
      next unless v and !v.empty?

      operator = operator_for(field)

      # "me" value substitution
      if %w(assigned_to_id author_id user_id watcher_id updated_by last_updated_by).include?(field)
        if v.delete("me")
          if User.current.logged?
            v.push(User.current.id.to_s)
            v += User.current.group_ids.map(&:to_s) if %w(assigned_to_id watcher_id).include?(field)
          else
            v.push("0")
          end
        end
      end

      if field == 'project_id' || (self.type == 'ProjectQuery' && %w[id parent_id].include?(field))
        if v.delete('mine')
          v += User.current.memberships.map {|m| m.project_id.to_s}
        end
        if v.delete('bookmarks')
          v += User.current.bookmarked_project_ids
        end
      end

      if field =~ /^cf_(\d+)\.cf_(\d+)$/
        filters_clauses << sql_for_chained_custom_field(field, operator, v, $1, $2)
      elsif field =~ /cf_(\d+)$/
        # custom field
        filters_clauses << sql_for_custom_field(field, operator, v, $1)
      elsif field =~ /^cf_(\d+)\.(.+)$/
        filters_clauses << sql_for_custom_field_attribute(field, operator, v, $1, $2)
      elsif respond_to?(method = "sql_for_#{field.gsub('.', '_')}_field")
        # specific statement
        filters_clauses << send(method, field, operator, v)
      else
        # regular field
        filters_clauses << '(' + sql_for_field(field, operator, v, queried_table_name, field) + ')'
      end
    end if filters and valid?

    if (c = group_by_column) && c.is_a?(QueryCustomFieldColumn)
      # Excludes results for which the grouped custom field is not visible
      filters_clauses << c.custom_field.visibility_by_project_condition
    end

    #    filters_clauses << project_statement
    # filters_clauses.reject!(&:blank?)

    # filters_clauses.any? ? filters_clauses.join(' AND ') : nil

    #now start build the full statement, project filter is allways AND
    filters_clauses.reject!(&:blank?)
    and_clauses.reject!(&:blank?)
    and_statement = and_clauses.any? ? and_clauses.join(" AND ") : nil
    all_and_statement = ["#{project_statement}", "#{and_statement}"].reject(&:blank?)
    all_and_statement = all_and_statement.any? ? all_and_statement.join(" AND ") : nil

    # finish the traditional part. Now extended part
    # add the and_any first
    and_any_clauses.reject!(&:blank?)
    and_any_statement = and_any_clauses.any? ? "("+ and_any_clauses.join(" OR ") +")" : nil
    full_statement_ext_1 = ["#{all_and_statement}", "#{and_any_statement}"].reject(&:blank?)
    full_statement_ext_1 = full_statement_ext_1.any? ? full_statement_ext_1.join(and_any_op) : nil

    # then add the or_all
    or_all_clauses.reject!(&:blank?)
    or_all_statement = or_all_clauses.any? ? "("+ or_all_clauses.join(" AND ") +")" : nil
    full_statement_ext_2 = ["#{full_statement_ext_1}", "#{or_all_statement}"].reject(&:blank?)
    full_statement_ext_2 = full_statement_ext_2.any? ? full_statement_ext_2.join(or_all_op) : nil

    # then add the or_any
    or_any_clauses.reject!(&:blank?)
    or_any_statement = or_any_clauses.any? ? "("+ or_any_clauses.join(" OR ") +")" : nil
    filters_clauses.any? ? filters_clauses.join(' AND ') : nil
    full_statement = ["#{full_statement_ext_2}", "#{or_any_statement}"].reject(&:blank?)
    full_statement = full_statement.any? ? full_statement.join(or_any_op) : nil
    Rails.logger.info "STATEMENT #{full_statement}"
    return full_statement
  end

  def sql_for_field(field, operator, value, db_table, db_field, is_custom_filter=false)
    sql = ''
    case operator
    when "="
      if value.any?
        case type_for(field)
        when :date, :date_past
          sql = date_clause(db_table, db_field, parse_date(value.first),
                            parse_date(value.first), is_custom_filter)
        when :integer
          int_values = value.first.to_s.scan(/[+-]?\d+/).map(&:to_i).join(",")
          if int_values.present?
            if is_custom_filter
              sql =
                "(#{db_table}.#{db_field} <> '' AND " \
                  "CAST(CASE #{db_table}.#{db_field} WHEN '' THEN '0' " \
                  "ELSE #{db_table}.#{db_field} END AS decimal(30,3)) IN (#{int_values}))"
            else
              sql = "#{db_table}.#{db_field} IN (#{int_values})"
            end
          else
            sql = "1=0"
          end
        when :float
          if is_custom_filter
            sql =
              "(#{db_table}.#{db_field} <> '' AND " \
                "CAST(CASE #{db_table}.#{db_field} WHEN '' THEN '0' " \
                "ELSE #{db_table}.#{db_field} END AS decimal(30,3)) " \
                "BETWEEN #{value.first.to_f - 1e-5} AND #{value.first.to_f + 1e-5})"
          else
            sql = "#{db_table}.#{db_field} BETWEEN #{value.first.to_f - 1e-5} AND #{value.first.to_f + 1e-5}"
          end
        else
          sql = queried_class.send(:sanitize_sql_for_conditions, ["#{db_table}.#{db_field} IN (?)", value])
        end
      else
        # IN an empty set
        sql = "1=0"
      end
    when "!"
      if value.any?
        sql =
          queried_class.send(
            :sanitize_sql_for_conditions,
            ["(#{db_table}.#{db_field} IS NULL OR #{db_table}.#{db_field} NOT IN (?))", value]
          )
      else
        # NOT IN an empty set
        sql = "1=1"
      end
    when "!*"
      sql = "#{db_table}.#{db_field} IS NULL"
      sql += " OR #{db_table}.#{db_field} = ''" if is_custom_filter || [:text, :string].include?(type_for(field))
    when "*"
      sql = "#{db_table}.#{db_field} IS NOT NULL"
      sql += " AND #{db_table}.#{db_field} <> ''" if is_custom_filter || [:text, :string].include?(type_for(field))
    when ">="
      if [:date, :date_past].include?(type_for(field))
        sql = date_clause(db_table, db_field, parse_date(value.first), nil, is_custom_filter)
      else
        if is_custom_filter
          sql =
            "(#{db_table}.#{db_field} <> '' AND " \
              "CAST(CASE #{db_table}.#{db_field} WHEN '' THEN '0' " \
              "ELSE #{db_table}.#{db_field} END AS decimal(30,3)) >= #{value.first.to_f})"
        else
          sql = "#{db_table}.#{db_field} >= #{value.first.to_f}"
        end
      end
    when "<="
      if [:date, :date_past].include?(type_for(field))
        sql = date_clause(db_table, db_field, nil, parse_date(value.first), is_custom_filter)
      else
        if is_custom_filter
          sql =
            "(#{db_table}.#{db_field} <> '' AND " \
              "CAST(CASE #{db_table}.#{db_field} WHEN '' THEN '0' " \
              "ELSE #{db_table}.#{db_field} END AS decimal(30,3)) <= #{value.first.to_f})"
        else
          sql = "#{db_table}.#{db_field} <= #{value.first.to_f}"
        end
      end
    when "><"
      if [:date, :date_past].include?(type_for(field))
        sql = date_clause(db_table, db_field, parse_date(value[0]), parse_date(value[1]), is_custom_filter)
      else
        if is_custom_filter
          sql =
            "(#{db_table}.#{db_field} <> '' AND CAST(CASE #{db_table}.#{db_field} " \
              "WHEN '' THEN '0' ELSE #{db_table}.#{db_field} END AS decimal(30,3)) " \
              "BETWEEN #{value[0].to_f} AND #{value[1].to_f})"
        else
          sql = "#{db_table}.#{db_field} BETWEEN #{value[0].to_f} AND #{value[1].to_f}"
        end
      end
    when "o"
      if field == "status_id"
        sql =
          "#{queried_table_name}.status_id IN " \
            "(SELECT id FROM #{IssueStatus.table_name} " \
            "WHERE is_closed=#{self.class.connection.quoted_false})"
      end
    when "c"
      if field == "status_id"
        sql =
          "#{queried_table_name}.status_id IN " \
            "(SELECT id FROM #{IssueStatus.table_name} " \
            "WHERE is_closed=#{self.class.connection.quoted_true})"
      end
    when "><t-"
      # between today - n days and today
      sql = relative_date_clause(db_table, db_field, - value.first.to_i, 0, is_custom_filter)
    when ">t-"
      # >= today - n days
      sql = relative_date_clause(db_table, db_field, - value.first.to_i, nil, is_custom_filter)
    when "<t-"
      # <= today - n days
      sql = relative_date_clause(db_table, db_field, nil, - value.first.to_i, is_custom_filter)
    when "t-"
      # = n days in past
      sql = relative_date_clause(db_table, db_field, - value.first.to_i, - value.first.to_i, is_custom_filter)
    when "><t+"
      # between today and today + n days
      sql = relative_date_clause(db_table, db_field, 0, value.first.to_i, is_custom_filter)
    when ">t+"
      # >= today + n days
      sql = relative_date_clause(db_table, db_field, value.first.to_i, nil, is_custom_filter)
    when "<t+"
      # <= today + n days
      sql = relative_date_clause(db_table, db_field, nil, value.first.to_i, is_custom_filter)
    when "t+"
      # = today + n days
      sql = relative_date_clause(db_table, db_field, value.first.to_i, value.first.to_i, is_custom_filter)
    when "t"
      # = today
      sql = relative_date_clause(db_table, db_field, 0, 0, is_custom_filter)
    when "ld"
      # = yesterday
      sql = relative_date_clause(db_table, db_field, -1, -1, is_custom_filter)
    when "nd"
      # = tomorrow
      sql = relative_date_clause(db_table, db_field, 1, 1, is_custom_filter)
    when "w"
      # = this week
      first_day_of_week = l(:general_first_day_of_week).to_i
      day_of_week = User.current.today.cwday
      days_ago =
        if day_of_week >= first_day_of_week
          day_of_week - first_day_of_week
        else
          day_of_week + 7 - first_day_of_week
        end
      sql = relative_date_clause(db_table, db_field, - days_ago, - days_ago + 6, is_custom_filter)
    when "lw"
      # = last week
      first_day_of_week = l(:general_first_day_of_week).to_i
      day_of_week = User.current.today.cwday
      days_ago =
        if day_of_week >= first_day_of_week
          day_of_week - first_day_of_week
        else
          day_of_week + 7 - first_day_of_week
        end
      sql = relative_date_clause(db_table, db_field, - days_ago - 7, - days_ago - 1, is_custom_filter)
    when "l2w"
      # = last 2 weeks
      first_day_of_week = l(:general_first_day_of_week).to_i
      day_of_week = User.current.today.cwday
      days_ago =
        if day_of_week >= first_day_of_week
          day_of_week - first_day_of_week
        else
          day_of_week + 7 - first_day_of_week
        end
      sql = relative_date_clause(db_table, db_field, - days_ago - 14, - days_ago - 1, is_custom_filter)
    when "nw"
      # = next week
      first_day_of_week = l(:general_first_day_of_week).to_i
      day_of_week = User.current.today.cwday
      from =
        -(
          if day_of_week >= first_day_of_week
            day_of_week - first_day_of_week
          else
            day_of_week + 7 - first_day_of_week
          end
        ) + 7
      sql = relative_date_clause(db_table, db_field, from, from + 6, is_custom_filter)
    when "m"
      # = this month
      date = User.current.today
      sql = date_clause(db_table, db_field,
                        date.beginning_of_month, date.end_of_month,
                        is_custom_filter)
    when "lm"
      # = last month
      date = User.current.today.prev_month
      sql = date_clause(db_table, db_field,
                        date.beginning_of_month, date.end_of_month,
                        is_custom_filter)
    when "nm"
      # = next month
      date = User.current.today.next_month
      sql = date_clause(db_table, db_field,
                        date.beginning_of_month, date.end_of_month,
                        is_custom_filter)
    when "y"
      # = this year
      date = User.current.today
      sql = date_clause(db_table, db_field,
                        date.beginning_of_year, date.end_of_year,
                        is_custom_filter)
    when "~"
      sql = sql_contains("#{db_table}.#{db_field}", value.first)
    when "!~"
      sql = sql_contains("#{db_table}.#{db_field}", value.first, :match => false)
    when "*~"
      sql = sql_contains("#{db_table}.#{db_field}", value.first, :all_words => false)
    when "^"
      sql = sql_contains("#{db_table}.#{db_field}", value.first, :starts_with => true)
    when "$"
      sql = sql_contains("#{db_table}.#{db_field}", value.first, :ends_with => true)
    when "ev", "!ev", "cf"
      # has been,  has never been, changed from
      if queried_class == Issue && value.present?
        neg = (operator.start_with?('!') ? 'NOT' : '')
        subquery =
          "SELECT 1 FROM #{Journal.table_name}" +
            " INNER JOIN #{JournalDetail.table_name} ON #{Journal.table_name}.id = #{JournalDetail.table_name}.journal_id" +
            " WHERE (#{Journal.visible_notes_condition(User.current, :skip_pre_condition => true)}" +
            " AND #{Journal.table_name}.journalized_type = 'Issue'" +
            " AND #{Journal.table_name}.journalized_id = #{db_table}.id" +
            " AND #{JournalDetail.table_name}.property = 'attr'" +
            " AND #{JournalDetail.table_name}.prop_key = '#{db_field}'" +
            " AND " +
            queried_class.send(:sanitize_sql_for_conditions, ["#{JournalDetail.table_name}.old_value IN (?)", value.map(&:to_s)]) +
            ")"
        sql_ev =
          if %w[ev !ev].include?(operator)
            " OR " + queried_class.send(:sanitize_sql_for_conditions, ["#{db_table}.#{db_field} IN (?)", value.map(&:to_s)])
          else
            ''
          end
        sql = "#{neg} (EXISTS (#{subquery})#{sql_ev})"
      else
        sql = '1=0'
      end
    when "match"
      sql = sql_for_match_operators(field, operator, value, db_table, db_field, is_custom_filter)
    when "!match"
      sql = sql_for_match_operators(field, operator, value, db_table, db_field, is_custom_filter)
    else
      raise QueryError, "Unknown query operator #{operator}"
    end

    return sql
  end

  def sql_for_match_operators(field, operator, value, db_table, db_field, is_custom_filter=false)
    sql = ''
    v = "(" + value.first.strip + ")"
    match = true
    op = ""
    term = ""
    in_term = false
    in_bracket = false
    v.chars.each do |c|
      if (!in_bracket && "()+~!".include?(c) && in_term  ) || (in_bracket && "}".include?(c))
        if !term.empty?
          sql += "(" + sql_contains("#{db_table}.#{db_field}", term, match) + ")"
        end
        #reset
        op = ""
        term = ""
        in_term = false
        in_bracket = (c == "{")
      end
      if in_bracket && (!"{}".include? c)
        term += c
        in_term = true
      else
        case c
        when "{"
          in_bracket = true
        when "}"
          in_bracket = false
        when "("
          sql += c
        when ")"
          sql += c
        when "+"
          sql += " AND " if sql.last != "("
        when "~"
          sql += " OR " if sql.last != "("
        when "!"
          sql += " NOT "
        else
          if c != " "
            term += c
            in_term = true
          end
        end
      end
    end

    if operator.include? "!"
      sql = " NOT " + sql
    end
    Rails.logger.info "MATCH EXPRESSION: V=#{value.first}, SQL=#{sql}"
    return sql
  end

end

Query.operators_by_filter_type.store(:text, [  "~", "!~", "^", "$", "!*", "*", "match", "!match" ])
Query.operators.store("match", :label_match)
Query.operators.store("!match", :label_not_match)

Query.send(:prepend, QueryPatch)