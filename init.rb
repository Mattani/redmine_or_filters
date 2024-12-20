Redmine::Plugin.register :redmine_or_filter do
  name 'Redmine or filter'
  author 'Alexey Smirnov'
  description 'This is a plugin for Redmine which adds OR filters. Development based on discussion https://www.redmine.org/issues/4939'
  version '5.1'
  url 'https://github.com/apsmir/redmine_or_filters'
end

#requires_redmine :version  => '5.1'

require_dependency File.dirname(__FILE__) + '/lib/queries_helper_patch'
require_dependency File.dirname(__FILE__) + '/lib/issue_query_patch'
require_dependency File.dirname(__FILE__) + '/lib/query_patch'