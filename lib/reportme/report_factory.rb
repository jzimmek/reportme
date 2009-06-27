require 'reportme/report'
require 'reportme/mailer'

class Object
  
  def self.dsl_attr(name, opts={})

    self.class.send(:define_method, name) do |value|
      key = "@@#{name}".to_sym
      class_variable_set(key, value)
    end
    
    
    self.class.send(:define_method, "#{name}_value".to_sym) do
      class_variable_get("@@#{name}".to_sym)
    end

    self.class.send(:define_method, "#{name}_reset".to_sym) do
      default = opts[:default].try(:call)
      class_variable_set("@@#{name}".to_sym, default)
    end

    default = opts[:default].try(:call)
    send(name, default)

  end
  
end

module Reportme
  class ReportFactory

    dsl_attr :reports,        :default => lambda{ [] }
    dsl_attr :subscribtions,  :default => lambda{ {} }
    dsl_attr :properties,     :default => lambda{ {} }
    dsl_attr :since
    dsl_attr :init
  
    def initialize
      @report_exists_cache = []
    end
    
    def self.connection(properties)
      ActiveRecord::Base.establish_connection(@@properties = properties)
    end
    
    def self.smtp(settings)
      ActionMailer::Base.smtp_settings = settings
    end
    
    def mail(from, recipients, subject, body, attachments=[])
      Mailer.deliver_message(from, recipients, subject, body, attachments)
    end
  
    def self.since(since)
      raise "since has already been set to '#{@@since}' and cannot be changed to: '#{since}'"   if @@since
      raise "since cannot be in the future"                                                     if since.future?
      
      @@since = since.to_date
    end
  
    def self.init(&block)
      raise "only one init block allowed" if @@init
      @@init = block;
    end
  
    def self.periods(today)

      r = []
      p = []

      # period "today" will never be generated for previous days
      p << :today if today.to_date == Date.today
      p += [:day, :week, :calendar_week, :month, :calendar_month]

      p.each do |period|
      
        von, bis = case period
          when :today
            [today, today]
          when :day
            [today - 1.day, today - 1.day]
          when :week
            [today - 1.week, today - 1.day]
          when :calendar_week
            day_lastweek = today.to_date - 7.days
            monday = day_lastweek - (day_lastweek.cwday - 1).days
            [monday, monday + 6.days]
          when :month
            [today - 1.day - 30.days, today - 1.day]
          when :calendar_month
            n = today - 1.month
            [n.beginning_of_month, n.end_of_month]
        end
      
        von = von.to_datetime
        bis = bis.to_datetime + 23.hours + 59.minutes + 59.seconds
      
        r << {:name => period, :von => von, :bis => bis}

      end
    
      r
    end
  
    def report_information_table_name
      "report_informations"
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
    
    def schema_name
      schema = @@properties[:database]
      raise "missing :database in connection properties" unless schema
      schema
    end
    
    def columns(table_name)
      sql = <<-SQL
      select
        column_name
      from
        information_schema.columns
      where
        table_schema = '#{schema_name}'
        and table_name = '#{table_name}'
      ;
      SQL
      select_values(sql)
    end
    
    def ensure_report_table_exist(report, period)
      unless report.table_exist?(period)
        table_name  = report.table_name(period)
        sql         = report.sql('0000-00-00 00:00:00', '0000-00-00 00:00:00', period)

        exec("create table #{table_name} ENGINE=InnoDB default CHARSET=utf8 as #{sql} limit 0;")
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
      end
    end
    
    def try_report_by_daily_reports(report, period_name, _von, num_days, num_days_required)
      table_name = report.table_name(period_name)

      von = _von.strftime("%Y-%m-%d 00:00:00")
      bis = (_von + num_days.days).strftime("%Y-%m-%d 23:59:59")
      
      existing_daily_reports = select_value(<<-SQL
        select
          count(1) cnt
        from
          #{report_information_table_name}
        where
          report = '#{report.table_name(:day)}'
          and von between '#{von}' and '#{(_von + num_days.days).strftime("%Y-%m-%d 00:00:00")}'
      SQL
      ).to_i
      
      puts "#{period_name}ly report depends on #{num_days_required} daily reports ... #{existing_daily_reports} daily found"
      
      if existing_daily_reports == num_days_required
        
        column_names = ["'#{von}' as von"]
        column_names += columns(table_name).find_all{|c|c != "von"}.collect{|c|"d.#{c} as #{c}"}

        ActiveRecord::Base.transaction do
          exec("insert into #{report_information_table_name} values ('#{table_name}', '#{von}', '#{bis}', now());")
          exec("insert into #{table_name} select #{column_names.join(',')} from #{report.table_name(:day)} as d where d.von between '#{von}' and '#{(_von + num_days.days).strftime("%Y-%m-%d 00:00:00")}';")

          self.class.notify_subscriber(report.name, period_name, _von)
        end
      end
    end
    
    def run
    
      @@init.call              if @@init
      @@since = Date.today     unless @@since
    
      ensure_report_informations_table_exist
      
      periods_queue = []
      
      while !@@since.future?
        ReportFactory.periods(@@since).each do |period|
          periods_queue << period
        end
        @@since += 1.day
      end
      
      # we will generate all daily reports first.
      # this will speed up generation of weekly and monthly reports.
      
      periods_queue.reject{|p| p[:name] != :day}.each do |period|
        report_period(period)
      end

      periods_queue.reject{|p| p[:name] == :day}.each do |period|
        report_period(period)
      end
      
    end
  
    def report_period(period)
      
      @@reports.each do |r|
      
        period_name = period[:name]
      
        next unless r.wants_period?(period_name)

        _von = period[:von]
        _bis = period[:bis]

        von = _von.strftime("%Y-%m-%d 00:00:00")
        bis = _bis.strftime("%Y-%m-%d 23:59:59")

        table_name = r.table_name(period_name)

        table_exist   = r.table_exist?(period_name)
        sql           = r.sql(von, bis, period_name)
    
        puts "report: #{r.table_name(period_name)} von: #{von}, bis: #{bis}"

        ensure_report_table_exist(r, period_name)
        
        report_exists = report_exists?(table_name, von, bis)
        
        try_report_by_daily_reports(r, :week, _von, 6, 7)                                     if period_name == :week && !report_exists
        try_report_by_daily_reports(r, :calendar_week, _von, 6, 7)                            if period_name == :calendar_week && !report_exists
        
        # TODO: implement monat by daily reports
        # try_report_by_daily_reports(r, :month, _von, 29 + (_von.end_of_month.day == 31 ? 1 : 0), 30)  if period_name == :month && !report_exists
        
        try_report_by_daily_reports(r, :calendar_month, _von, _bis.day - _von.day, _bis.day)  if period_name == :calendar_month && !report_exists

        report_exists = report_exists?(table_name, von, bis)
        
        if !report_exists || period_name == :today
          ActiveRecord::Base.transaction do
            exec("insert into #{report_information_table_name} values ('#{table_name}', '#{von}', '#{bis}', now());") unless report_exists
        
            if period_name == :today
              exec("truncate #{table_name};")
            end
          
            exec("insert into #{table_name} #{sql};")
            
            self.class.notify_subscriber(r.name, period_name, _von)
          end
        end

    
      end
      
    end
  
    def exec(sql)
      puts "// ------------------------"
      puts "exec: #{sql}"
      puts "------------------------ //"
      ActiveRecord::Base.connection.execute(sql)
    end
    
    def select_value(sql)
      puts "// ------------------------"
      puts "select_value: #{sql}"
      puts "------------------------ //"
      ActiveRecord::Base.connection.select_value(sql)
    end

    def select_one(sql)
      puts "// ------------------------"
      puts "select_one: #{sql}"
      puts "------------------------ //"
      ActiveRecord::Base.connection.select_one(sql)
    end

    def select_all(sql)
      puts "// ------------------------"
      puts "select_all: #{sql}"
      puts "------------------------ //"
      ActiveRecord::Base.connection.select_all(sql)
    end

    def select_rows(sql)
      puts "// ------------------------"
      puts "select_rows: #{sql}"
      puts "------------------------ //"
      ActiveRecord::Base.connection.select_rows(sql)
    end

    def select_values(sql)
      puts "// ------------------------"
      puts "select_values: #{sql}"
      puts "------------------------ //"
      ActiveRecord::Base.connection.select_values(sql)
    end

    def self.has_subscribtion?(report_name)
      !@@subscribtions[report_name].blank?
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
    
    def self.notify_subscriber(report_name, period, von)
      
      (@@subscribtions[report_name] || []).each do |subscription|
        begin
          subscription.call(period, von)
        rescue Exception => e
          puts e
        end
      end
      
    end
  
    def self.report(name, &block)
      
      name = name.to_sym
      
      r = Report.new(self, name)
      r.instance_eval(&block)
    
      @@reports << r
    end
  
  end
end