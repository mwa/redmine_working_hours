class WorkingHoursController < ApplicationController
  unloadable #Don't understand it, but prevents exception "A copy of ApplicationController has been removed from the module tree but is still active"
  layout 'base'
  before_filter :require_login
  accept_key_auth :index

  def index
    if 'ics' == params[:export]
      params[:duration] ||= 365
      params[:begindate] ||= Date.today - params[:duration].to_s.to_i
      params[:enddate] ||= Date.today      
    else
      params[:begindate] ||= Date.today
      params[:enddate] ||= Date.today
    end
    params[:begindate] = Date.today if params[:begindate].to_date > Date.today
    params[:enddate] = params[:begindate] if params[:enddate].to_date < params[:begindate].to_date
    conditions = ["user_id=? AND workday >= ? AND workday <= ?",
      User.current.id, params[:begindate], params[:enddate]]
    params[:filter] ||= {}
    if !params[:filter][:project_id].nil? && !params[:filter][:project_id].empty? then
        conditions.first << " AND project_id=?"
        conditions << params[:filter][:project_id]
    end
    @working_hour_count = WorkingHours.count(:conditions => conditions)
    @working_hour_pages = Paginator.new self, @working_hour_count,
      per_page_option,
      params['page']								
    @working_hours =  WorkingHours.find :all, :conditions => conditions
    @minutes_total = @working_hours.inject(0) { |sum, j| sum + j.minutes }

    send_csv and return if 'csv' == params[:export]    
    send_ics and return if 'ics' == params[:export]

    @working_hours =  WorkingHours.find :all,:order => "#{WorkingHours.table_name}.starting DESC",
      :conditions => conditions,
      :limit  =>  @working_hour_pages.items_per_page,
      :offset =>  @working_hour_pages.current.offset
    render :action => 'index', :layout => false if request.xhr?
  end

  def new
    @working_hours = WorkingHours.new
    @working_hours.user = User.current
    @working_hours.starting = Time.now
    @working_hours.break = 0
    @users = User.find(:all)
  end

  def create
    @working_hours = WorkingHours.new(params[:working_hours])
    @working_hours.workday ||= Time.now
    working_hours_calculations
    if @working_hours.save
      flash[:notice] = 'WorkingHours was successfully created.'
      redirect_to :action => 'index'
    else
      render :action => 'new'
    end
  end

  def edit
    @working_hours = WorkingHours.find(params[:id])
    @duration = '%.1f' % (@working_hours.minutes/60.0)
    @users = User.find(:all)
  end

  def update
    @working_hours = WorkingHours.find(params[:id])
    @working_hours.attributes = params[:working_hours]
    working_hours_calculations
    if @working_hours.save
      flash[:notice] = 'WorkingHours was successfully updated.'
      redirect_to :action => 'index'
    else
      render :action => 'edit'
    end
  end

  def destroy
    WorkingHours.find(params[:id]).destroy
    redirect_to :action => 'index'
  end

  def working_hours_calculations
    case params['subform']
      when 'Timestamps'
        if params['running']
          @working_hours.ending = nil
        end
      when 'Duration'
        @working_hours.starting = Time.local(@working_hours.workday.year, @working_hours.workday.month, @working_hours.workday.day)
        @working_hours.ending = @working_hours.starting + params['duration'].to_f * 3600
    end
  end

  #------------- timer
  
  def startstop
    project_id = params[:project_id].to_i
    issue_id = params[:issue_id].to_i
    @cur_entry = startstop_task(User.current, project_id, issue_id)
    render(:partial => 'my/blocks/workinghours')
  end

  def break
    @cur_entry = startstop_task(User.current, nil, nil, true)
    render(:partial => 'my/blocks/workinghours')
  end

  private

  MINGAP = 60

  def startstop_task(user, new_project_id, new_issue_id, breakflag=false)
    logger.debug "startstop user #{user.name} task: #{new_project_id} break: #{breakflag}"
    starting = Time.now

    cur = WorkingHours.find_current(user)
    start_task = !(breakflag || new_project_id.nil? || new_project_id == 0)

    #stop current task
    if !cur.nil? && cur.running? then
      logger.debug "stop entry #{cur.id} task: #{cur.project_id}"
      if new_project_id == cur.project_id && new_issue_id == cur.issue_id then
        #Same task -> stop only
        start_task = false
      end
      cur.ending = starting
      if cur.ending - cur.starting < MINGAP && start_task then
        #replace short entry by new one
        starting = cur.starting
        cur.destroy
      else
        cur.save
      end
    elsif start_task then
      #check short entries or short gaps
      cur = WorkingHours.find(:first, :conditions => ["user_id=?", user.id], :order => "#{WorkingHours.table_name}.starting DESC")
      if !cur.nil? then
        if cur.ending - cur.starting < MINGAP then
          #replace short entry by new one
          starting = cur.starting
          cur.destroy
        elsif starting - cur.ending < MINGAP then
          #no gap
          starting = cur.ending
        end
        cur = nil
      end
    end

    #start new task
    if start_task then
      prev = WorkingHours.find(:first, :conditions => ["user_id=? AND project_id=?", user.id, new_project_id], :order => "#{WorkingHours.table_name}.starting DESC")
      cur = WorkingHours.start(user, starting)
      logger.debug "start entry #{cur.id} task: #{cur.project_id}"
      cur.project_id = new_project_id
      cur.issue_id = new_issue_id
      cur.comments = prev.comments if !prev.nil? && starting - prev.ending < 10*3600
      cur.save!
    end

    cur
  rescue Exception => e
    logger.error "Error in startstop user #{user.name} task: #{new_project_id} break: #{breakflag} " + e
    nil
  end

  def send_csv
    require 'csv'
    ic = Iconv.new(l(:general_csv_encoding), 'UTF-8')    
    export = StringIO.new
    CSV::Writer.generate(export, l(:general_csv_separator)) do |csv|
      # csv header fields
      headers = ['User', 'Project', 'Ticket', 'Title', 'Date', 'Begin', 'Break', 'End', 'Comment', 'Duration' ]
      csv << headers.collect {|c| begin; ic.iconv(c.to_s); rescue; c.to_s; end }
      # csv lines
      @working_hours.each do |entry|
        fields = [(entry.user ? entry.user.name : nil),
                  entry.project.name,
                  (entry.issue ? entry.issue_id : nil),
                  (entry.issue ? entry.issue.subject : nil),
                  entry.workday.to_formatted_s(:european),
                  (entry.starting ? entry.starting.to_formatted_s(:time) : nil),
                  entry.break,
                  (entry.ending ? entry.ending.to_formatted_s(:time) : nil),
                  entry.comments,
                  entry.minutes
                  ]
        csv << fields.collect {|c| begin; ic.iconv(c.to_s); rescue; c.to_s; end }
      end
    end
    export.rewind
    send_data(export.read, :type => 'text/csv; header=present', :filename => 'export.csv')
  end
  
  def send_ics
    ic = Iconv.new(l(:general_csv_encoding), 'UTF-8')
    export = StringIO.new
    export << ic.iconv("BEGIN:VCALENDAR\n")
    export << ic.iconv("VERSION:2.0\n")
    export << ic.iconv("PRODID:-//Sourcepole//NONSGML Redmine Working Hours//EN\n")
    @working_hours.each do |entry|
      export << ic.iconv("BEGIN:VEVENT\n")
      export << ic.iconv("DTSTART:#{date_to_utc_text(entry.starting)}\n")
      export << ic.iconv("DTEND:#{date_to_utc_text(entry.ending)}\n")
      task = entry.issue ? "\\n##{entry.issue_id} #{entry.issue.subject}": ""
      export << ic.iconv("SUMMARY:#{entry.project.name}#{task}\n")
      comments = entry.comments.to_s.gsub(/\r\n|\n/, "\\n")
      export << ic.iconv("DESCRIPTION:#{comments}\n")
      export << ic.iconv("ATTENDEE:#{entry.user ? "#{entry.user.firstname} #{entry.user.lastname}" : ""}\n")
      export << ic.iconv("END:VEVENT\n\n")
    end
    export << ic.iconv("END:VCALENDAR\n")
    export.rewind
    send_data(export.read, :type => 'text/calendar', :filename => 'export.ics')    
  end

  # convert local date to UTC date text "%Y%m%dT%H%M%SZ"
  def date_to_utc_text(date, hour_shift = -2)
    if Time::DATE_FORMATS[:utc_prefix].nil?
      # init custom date formats
      Time::DATE_FORMATS[:utc_prefix] = "%Y%m%dT"
      Time::DATE_FORMATS[:utc_hours] = "%H"
      Time::DATE_FORMATS[:utc_postfix] = "%M%SZ"
    end

    text = ""
    unless date.nil?
      prefix = date.to_formatted_s(:utc_prefix)
      hours = date.to_formatted_s(:utc_hours).to_i + hour_shift
      postfix = date.to_formatted_s(:utc_postfix)
      text = prefix + ("%02d" % hours) + postfix
    end
    text
  end
end
