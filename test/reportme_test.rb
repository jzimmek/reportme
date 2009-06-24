require 'test_helper'

class ReportmeTest < Test::Unit::TestCase

  def setup
    exec("use report_me_test")
    exec "drop table if exists visits"
    exec <<-SQL
      create
        table visits
        (
          id bigint auto_increment,
          channel varchar(255),
          created_at datetime,
          primary key (id)
        )
    SQL
  end
  
  def create_visit_report_factory(wanted_periods=nil)
    
    @rme = Reportme::ReportFactory.create do
      report :visits do
        periods(wanted_periods)
        source do |von, bis|
          <<-SQL
          select
            date('#{von}') as datum,
            channel,
            count(1) as cnt
          from
            visits
          where
            created_at between '#{von}' and '#{bis}'
          group by
            date(created_at),
            channel
          SQL
        end
      end
    end
    
    @rme
  end
  
  def exec(sql)
    ActiveRecord::Base.connection.execute(sql)
  end

  def one(sql)
    ActiveRecord::Base.connection.select_one(sql)
  end

  def teardown
    @rme.reset
    exec("truncate visits;");
  end

  should "create one visitor in the today report for channel sem" do
    exec("insert into visits values (null, 'sem', now())");
    create_visit_report_factory.run
    assert_equal 1, one("select count(1) as cnt from visits_today where channel = 'sem' and datum = curdate()")["cnt"].to_i
  end
  
  should "create two visitors in the today report for channel sem" do
    exec("insert into visits values (null, 'sem', now())");
    exec("insert into visits values (null, 'sem', now())");
    create_visit_report_factory.run
    assert_equal 2, one("select cnt from visits_today where channel = 'sem' and datum = curdate()")["cnt"].to_i
  end
  
  should "create visitors in the today report for channel sem and seo" do
    exec("insert into visits values (null, 'sem', now())");
    exec("insert into visits values (null, 'sem', now())");
    exec("insert into visits values (null, 'seo', now())");
    exec("insert into visits values (null, 'sem', now())");
    exec("insert into visits values (null, 'seo', now())");
    create_visit_report_factory.run
    assert_equal 2, one("select cnt from visits_today where channel = 'seo' and datum = curdate()")["cnt"].to_i
    assert_equal 3, one("select cnt from visits_today where channel = 'sem' and datum = curdate()")["cnt"].to_i
  end
  
  should "create visitors in the day report for channel sem and seo" do
    exec("insert into visits values (null, 'sem', date_sub(curdate(), interval 1 day));");
    exec("insert into visits values (null, 'sem', date_sub(curdate(), interval 1 day));");
    exec("insert into visits values (null, 'seo', date_sub(curdate(), interval 1 day));");
    exec("insert into visits values (null, 'sem', date_sub(curdate(), interval 1 day));");
    exec("insert into visits values (null, 'seo', date_sub(curdate(), interval 1 day));");
    create_visit_report_factory([:today, :day]).run
    assert_equal 2, one("select cnt from visits_day where channel = 'seo' and datum = date_sub(curdate(), interval 1 day)")["cnt"].to_i
    assert_equal 3, one("select cnt from visits_day where channel = 'sem' and datum = date_sub(curdate(), interval 1 day)")["cnt"].to_i
  end
  
  # should "report a week as 7 days since yesterday" do
  #   
  # end
  
  # should "handle today and day periods but nothing else" do
  # end
  
end
