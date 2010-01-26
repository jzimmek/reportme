module Reportme
  class Report
  
    attr_accessor :name
    attr_accessor :setup_callback, :inserted_callback
    
    def initialize(report_factory, name, opts={})
      
      name = name.to_sym
      
      opts = {
        :temporary => false,
        :engine => "InnoDB",
        :table_prefix => nil
      }.merge(opts)
      
      @report_factory = report_factory
      @name = name
      @depends_on = []
      @histories = []

      @temporary    = opts[:temporary]
      @engine       = opts[:engine]
      @table_prefix = opts[:table_prefix]
    end
  
    def engine
      @engine
    end
  
    def temporary?
      @temporary
    end
    
    def source(&block)
      @source = block
    end
    
    def histories(histories=[])
      @histories = histories
    end
    
    def historice?(history)
      @histories.include?(history)
    end
    
    def depends_on(dependencies=[])
      dependencies = dependencies.collect{|d| d.to_sym}
      @depends_on += dependencies
    end
    
    def dependencies
      @depends_on
    end
    
    def setup(&block)
      @setup_callback = block
    end

    def inserted(&block)
      @inserted_callback = block
    end
    
    def sql(von, bis, period_name)
      raw = @source.call(von, bis, period_name)
      
      <<-SQL
        select
          '#{von}' as von,
          rtmp1.*
        from (
          #{raw}
          ) rtmp1
      SQL
      
    end
  
    def table_name(period)
      prefix = ""
      prefix << "tmp_" if temporary?
      prefix << @table_prefix + "_" if @table_prefix
      "#{prefix}#{name}_#{period}"
    end
  
    def exec(sql);            @report_factory.exec(sql);            end
    def select_value(sql);    @report_factory.select_value(sql);    end
    def select_values(sql);   @report_factory.select_values(sql);   end
    def select_all(sql);      @report_factory.select_all(sql);      end
    def select_rows(sql);     @report_factory.select_rows(sql);     end
    def columns(table_name);  @report_factory.columns(table_name);  end
  
  end
end