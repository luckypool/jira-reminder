require 'jira'
require 'yaml'
require 'active_support'
require 'active_support/core_ext'
require 'time'
require 'pp'
require 'pry-byebug'

class Notifyer
  attr_reader :room, :client

  def initialize(credential, room='test')
    @room = room
    @nickname = 'jira watcher'
    # @client = # Client.new(credential, options)
  end

  def notify(message, color: 'yellow')
    if message.class == String
      puts message
    else
      message.each do |m|
        puts " " + m
      end
    end
  end
end


class JIRAWatcher
  UNKNOWN_COMPONENT_NAME = 'UNKNOWN_COMOPONENT'

  attr_reader :client, :jira_options, :project, :fix_version, :fix_version_url, :raw_issues, :grouped_issues, :notifier

  def initialize(credential)
    @jira_options = {
      username:     credential['jira']['username'],
      password:     credential['jira']['password'],
      site:         credential['jira']['site'],
      context_path: '',
      auth_type:    :basic
    }
    @client = JIRA::Client.new(@jira_options)

    fix_version = credential['jira']['fix_version']
    project_id  = credential['jira']['project_id']

    @project = @client.Project.find(project_id.to_i)
    @fix_version = @project.versions.find { |v| v.name == fix_version }
    @fix_version_url = [@jira_options[:site], 'projects', @project.key, 'versions', @fix_version.id].join('/')

    @raw_issues = @client.Issue.jql(base_jql, max_results: 200)

    @grouped_issues = @raw_issues.each_with_object({}) do |issue, hash|
      issue.components.each do |component|
        hash[component.name] ||= []
        hash[component.name].push(issue.dup)
      end
      if issue.components.empty?
        hash[UNKNOWN_COMPONENT_NAME] ||= []
        hash[UNKNOWN_COMPONENT_NAME].push(issue.dup)
      end
    end

    @notifier = Notifyer.new(credential)
  end

  def base_jql
    "project = #{@project.key} AND status not in (Closed) AND fixVersion = #{@fix_version.name} ORDER BY priority DESC, summary DESC"
  end

  def show_summary
    message = "#{@fix_version.name} のチケットサマリ #{@fix_version_url}"
    @notifier.notify(message, color: 'green')

    messages = []
    messages << "未クローズ合計: #{@raw_issues.count} 件"

    @grouped_issues.each do |component, issues|
      grouped_by_status = issues.group_by { |issue| issue.status.name }
      total = issues.count
      details = grouped_by_status.keys.map { |status| "#{status}: #{grouped_by_status[status].count} 件" }.join(', ')
      messages << "#{component}   合計: #{total} 件  (#{details})"
    end

    @notifier.notify(messages, color: 'green')

    message = "修正バージョン #{@fix_version.name} がついていないチケットが無いか再確認してください。"\
              "またコンポーネントの付け方も正しいか確認してください。"\
              "ここに載らないタスクは実施されない可能性があります。"

    @notifier.notify(message)
  end

  def notify_unknown_component_issues
    unknown_component_issues = @grouped_issues[UNKNOWN_COMPONENT_NAME] || []
    return if unknown_component_issues.empty?
    messages = ['下記のチケットにコンポーネントを付けて、タスクの担当区分を明示してください']
    unknown_component_issues.each do |issue|
      url = make_url_by_key(issue.key)
      messages << "#{url} #{issue.key} #{issue.assignee.displayName}  #{issue.summary}"
    end

    @notifier.notify(messages, color: 'red')
  end

  def notify_not_updated_issues
    @grouped_issues.each do |component, issues|
      next if component == UNKNOWN_COMPONENT_NAME
      messages = []
      threshold_days = 3
      if Time.now.wday < threshold_days
        # 土日は営業日外としとく
        threshold_days += threshold_days - Time.now.wday
      end
      issues.each do |issue|
        updated = Time.parse(issue.updated)
        if updated < threshold_days.days.ago.beginning_of_day
          url = make_url_by_key(issue.key)
          messages << "#{url} #{issue.key} 最終更新日（#{updated.to_date}） #{issue.summary}"
        end
      end
      next if messages.empty?

      messages.unshift("下記の #{component} ラベルのチケットは #{threshold_days.to_s} 日更新がありません！進捗どうですか？アサインは正しいですか？状況をコメントするなどお願いします。")

      @notifier.notify(messages, color: 'red')
    end
  end

  def make_url_by_key(key)
    [@jira_options[:site], 'browse', key].join('/')
  end
end

credential = YAML.load_file('./credential.yaml')

watcher = JIRAWatcher.new(credential)

# require 'pry-byebug'
# binding.pry

watcher.show_summary()
sleep 1

watcher.notify_unknown_component_issues()
sleep 1

watcher.notify_not_updated_issues()

puts 'hi!'

