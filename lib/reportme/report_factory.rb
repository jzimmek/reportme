require 'reportme/report'
require 'reportme/mailer'
require 'reportme/sql'
require 'reportme/period'

module Reportme
  class ReportFactory

    include Sql

    dsl_attr :reports,        :default => lambda{ [] }
    dsl_attr :subscribtions,  :default => lambda{ {} }
    dsl_attr :properties,     :default => lambda{ {} }
    dsl_attr :init
  
    def initialize
      @report_exists_cache = []
      @@report_creations = []
    end
    
    def self.connection(properties)
      ActiveRecord::Base.establish_connection(@@properties = properties)
    end
    
    def self.smtp(settings)
      ActionMailer::Base.smtp_settings = settings
    end
    
    def self.mail(from, recipients, subject, body, attachments=[])
      Mailer.deliver_message(from, recipients, subject, body, attachments)
    end
  
    def self.init(&block)
      raise "only one init block allowed" if @@init
      @@init = block;
    end
  
  
    def report_information_table_name
      "report_informations"
    end
    
    def remember_report_creation(report, period, von)
      @@report_creations << {:report => report, :period => period, :von => von}
    end
  
    def report_information_table_name_exist?
      select_value("show tables like '#{report_information_table_name}'") != nil
    end

    def report_exists?(name, von, bis)
      key = "#{name}__#{von}__#{bis}"

      return true if @report_exists_cache.include?(key)
      
      exists = select_value("select 1 from #{report_information_table_name} where report = '#{name}' and von = '#{von}' and bis = '#{bis}'") != nil
      
      @report_exists_cache << key if exists
      
      exists
    end
    
    def self.schema_name
      schema = @@properties[:database]
      raise "missing :database in connection properties" unless schema
      schema
    end

    
    def ensure_report_tables_exist(report, period_name)

      table_name  = report.table_name(period_name)
  
      unless table_exist?(table_name)

        sql = report.sql('0000-00-00 00:00:00', '0000-00-00 00:00:00', :day)

        exec("create table #{table_name} ENGINE=#{report.engine} default CHARSET=utf8 as #{sql} limit 0;")
        exec("alter table #{table_name} modify von datetime;")
        exec("alter table #{table_name} add index(von);")

        if period_name != :day
          exec("alter table #{table_name} add _day date after von;") 
          exec("alter table #{table_name} add index(_day);")
        end
        
        fix_varchar_sql = "select table_name, column_name from information_schema.columns where TABLE_SCHEMA = '#{@@properties[:database]}' and data_type = 'varchar' and character_maximum_length < 255;"
        
        select_all(fix_varchar_sql).each do |row|
          exec("alter table #{row['table_name']} modify #{row['column_name']} varchar(255)")
        end
        
        report.setup_callback.call(period_name) if report.setup_callback
      end
      
    end
    
    def ensure_report_informations_table_exist
      unless report_information_table_name_exist?
        ddl = <<-SQL
          create
            table report_informations
            (
              report varchar(255) not null,
              von datetime not null,
              bis datetime not null,
              created_at datetime not null,
              primary key (report, von, bis)
            )
            ENGINE=InnoDB default CHARSET=utf8;
        SQL
        exec(ddl)
        exec("alter table report_informations add index(report);") 
        exec("alter table report_informations add index(report, von);") 
      end
    end
    
    def validate_dependencies
      @@reports.each do |r|
        r.dependencies.each do |d|
          raise "report #{r.name} depends on non existing report #{d}" unless self.class.has_report?(d)
        end
      end
    end
    
    def __opts(opts={})
      opts = {
        :since => Date.today,
        :init => false,
        :notify_subscribers => true
      }.merge(opts)      
    end
    
    def historice(opts={})

      opts = __opts(opts)

      since = opts[:since]

      raise "since cannot be in the future" if since.future?

      __do_and_clean(:calendar_week, opts) do |period_name|
      
        loop do
          
          run_dependency_aware(@@reports) do |report|
            
            next if report.temporary?
            next unless report.historice?(period_name)
            
            __report_period(report, Period.calc(since, [period_name]).first)
          end

          since += 1.day
          break if since.future?
        end 

      end
    end
    
    def force_notification(report_name, period_name, since = Date.today)

      loop do

        period = Period.calc(since, [period_name]).first
        von = period[:von]

        puts "force notification: #{report_name}, #{period_name}"

        (@@subscribtions[report_name] || []).each do |subscription|
          puts "notify subscriber of report '#{report_name}' - period: '#{period_name}', von: '#{von}'"
          subscription.call(period_name, von, report_name)
        end

        since += 1.day
        break if since.future?
      end 
      
    end
    
    def run(opts={})

      opts = __opts(opts)

      opts[:init] = true

      since = opts[:since]
    
      raise "since cannot be in the future" if since.future?

      __do_and_clean(:day, opts) do |period_name|
        
        loop do
          
          run_dependency_aware(@@reports) do |report|
            __report_period(report, Period.calc(since, [period_name]).first)
          end
          
          yield(since) if block_given?

          since += 1.day
          break if since.future?
        end 

      end
      
    end
    
    def __do_and_clean(period_name, opts, &block)
      
      begin
        @@report_creations.clear
        
        ensure_report_informations_table_exist

        validate_dependencies
        
        @@init.call if @@init && opts[:init]

        run_dependency_aware(@@reports) do |report|
          
          if period_name != :day
            next unless report.historice?(period_name)
          end
          
          ensure_report_tables_exist(report, period_name)
        end

        block.call(period_name)
        
        self.class.__notify_subscriber if opts[:notify_subscribers]
        
      ensure
        @@reports.each do |report|
          
          if report.temporary?
            [:today, :day, :week, :calendar_week, :month, :calendar_month].each do |period|
              table_name = report.table_name(period)
              
              exec("delete from #{report_information_table_name} where report = '#{table_name}';")
              exec("drop table if exists #{table_name};")
            end
          end
          
        end
      end
    end
    
    def run_dependency_aware(reports, &block)

      dependencies = __dependency_hash
      reports = reports.dup
      
      while true

        break if reports.blank?

        num_run = 0

        reports.each do |r|

          unless dependencies[r.name].blank?
            puts "report ['#{r.name}'] waits on dependencies: #{dependencies[r.name].collect{|d|d.name}.join(',')}"
            next
          end

          block.call(r)

          dependencies.each_pair do |key, values|
            if values.include?(r)
              values.delete(r)
            end
          end

          num_run += 1
          reports.delete(r)

        end

        raise "deadlock" if num_run == 0

      end
      
    end
    
    def self.reset(report_name, periods=[:day, :calendar_week, :calendar_month])
      
      report_name = report_name.to_sym
      
      raise "could not reset unknown report '#{report_name}'" unless has_report?(report_name)
      
      report = report_by_name(report_name)
      
      periods.each do |period|
        table_name = report.table_name(period)
        exec("delete from report_informations where report = '#{table_name}';")
        exec("drop table if exists #{table_name};")
      end
      
    end
    
    def explain_sql(opts={})
      
      opts = {
        :since => Date.today,
        :report_names => @@reports.collect{|it|it.name}
      }.merge(opts)
      
      @@reports.each do |report|
        period = Period.calc(opts[:since]).first

        next unless opts[:report_names].include?(report.name)

        period_name   = period[:name]
        
        _von          = period[:von]
        _bis          = period[:bis]

        von = _von.strftime("%Y-%m-%d 00:00:00")
        bis = _bis.strftime("%Y-%m-%d 23:59:59")
        
        
        puts "++++++++++++++++++++++"
        puts "+++ #{report.name}"
        puts "++++++++++++++++++++++"
        sql = report.sql(von, bis, period_name)
        puts sql
      end
    end
    
    def self.print_dependency_tree(level=0, reports=@@reports)
      
      reports.each do |r|

        if level > 0
          (level + 1).times do
            print " "
          end
        end

        print "|-"
        
        puts r.name
        
        print_dependency_tree(level + 1, r.dependencies.collect{|d| report_by_name(d)})
        
      end
      
    end

    def __dependency_hash
      dependencies = {}
      @@reports.each do |r|
        
        dependencies[r.name] = []
        
        r.dependencies.each do |d|
          dependencies[r.name] << self.class.report_by_name(d)
        end
      end
      
      dependencies
    end
  
    def __report_period(r, period)
      
      period_name   = period[:name]
      _von          = period[:von]
      _bis          = period[:bis]

      von = _von.strftime("%Y-%m-%d 00:00:00")
      bis = _bis.strftime("%Y-%m-%d 23:59:59")

      table_name = r.table_name(period_name)

      table_exist   = table_exist?(period_name)
      sql           = r.sql(von, bis, period_name)

      report_exists = report_exists?(table_name, von, bis)

      unless report_exists
        ActiveRecord::Base.transaction do
          exec("insert into #{report_information_table_name} values ('#{table_name}', '#{von}', '#{bis}', now());") unless report_exists
          
          if period_name != :day
            
            table_name_day = r.table_name(:day)
            column_names = columns(table_name_day) - ["von"]
            
            sql = <<-SQL
              select
                '#{von}' as von,
                #{(['date(von) as _day'] + column_names).join("\n,")}
              from
                #{table_name_day}
              where
                von between '#{von}' and '#{bis}'
              group by
                #{(['date(von)'] + column_names).join("\n,")}
            SQL
            
          end

          exec("insert into #{table_name} #{sql};")
          
          r.inserted_callback.call(von, bis, period_name) if r.inserted_callback
        
          remember_report_creation(r, period_name, _von)
        end
      end
    end

    def self.has_subscribtion?(report_name)
      !@@subscribtions[report_name].blank?
    end
    
    def self.report_by_name(report_name)
      @@reports.find{|r|r.name == report_name}
    end
  
    def self.has_report?(report_name)
      !@@reports.find{|r|r.name == report_name}.blank?
    end
  
    def self.subscribe(report_name, &block)
      report_name = report_name.to_sym
      
      raise "report: #{report_name} does not exist" unless has_report?(report_name)
      
      existing = @@subscribtions[report_name] || (@@subscribtions[report_name] = [])
      existing << block
    end
    
    def self.__notify_subscriber
      @@report_creations.each do |creation|

        report_name = creation[:report].name
        period = creation[:period]
        von = creation[:von]

        (@@subscribtions[report_name] || []).each do |subscription|
          puts "notify subscriber of report '#{report_name}' - period: '#{period}', von: '#{von}'"
          subscription.call(period, von, report_name)
        end
      end
      
    end
  
    def self.report(name, opts={}, &block)
      
      r = Report.new(self, name, opts)
      r.instance_eval(&block)
    
      @@reports << r
    end
  
  end
end