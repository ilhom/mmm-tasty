# Filters added to this controller apply to all controllers in the application.
# Likewise, all the methods added will be available for all controllers.

class ApplicationController < ActionController::Base
  # Pick a unique cookie name to distinguish our session data from others'
  session :session_key => 'tasty'
  
  filter_parameter_logging :password
  # выключаем сесии для ботов
  session :off, :if => proc { |request| request.user_agent =~ /^(Googlebot|ApacheBench\/|WebAlta Crawler|YandexSomething\/|YandexBlog\/|Yandex\/|Feedfetcher-Google|msnbot\/|msnbot-media\/|StackRambler\/|Netvibes|NewsFire\/|Snarfer\/|TMCrawler|LiveJournal\.com|FeedTools\/|labrin_|Gigabot\/|Mail.Ru\/|TurtleScanner\/|ia_archiver|sogou spider|Yeti\/)/i }

  # after_filter { CachedModel.cache_reset }
  # before_filter :prelaunch_megasecrecy

  # меряем производительность только на реальном сайте
  if RAILS_ENV == 'production'
    around_filter do |controller, action|
      result = Benchmark.measure { action.call }

      Performance.transaction do
        perf = Performance.find_or_initialize_by_controller_and_action_and_day(controller.controller_name, controller.action_name, Time.now.to_date)
        perf.increment(:calls)
        perf.realtime ||= 0.0
        perf.realtime += result.real
        perf.stime += result.stime
        perf.utime += result.utime
        perf.cstime += result.cstime
        perf.cutime += result.cutime      
        perf.save!
      end
    end
  end

  # MAIN FILTERS
  attr_accessor   :current_site
  helper_method   :current_site

  attr_accessor   :current_user
  helper_method   :current_user
  
  attr_accessor   :standalone
  helper_method   :standalone

  before_filter :preload_current_site # loads @current_site
  before_filter :preload_current_user # loads @current_user
  
  before_filter :preload_essential_models
  
  protected
    def preload_essential_models
      Entry
    end
    
    def preload_current_site
      @standalone = false
      @current_site = nil

      # can be nil if web site is accessed by ip address or there was no 'Host:' header in request
      return true unless request.domain
      domain = request.host
      
      logger.debug "PCS: domain #{domain}"

      # 1. если в домене mmm-tasty.ru ...
      #    1.a   если адрес - www.mmm-tasty.ru / mmm-tasty.ru - выходим (true)
      #    1.b   если адрес - <reserved>.mmm-tasty.ru - перекидываем на главную и выходим (false)
      #    1.c   если адрес - www.<tlog>.mmm-tasty.ru - перекидываем на <tlog>.mmm-tasty.ru (false)
      #    1.d   если адрес - <tlog>.mmm-tasty.ru - выставляем current_site и выходим (true)
      #      d.1 перенаправляем на тлог, если у заданного тлога есть внешний домен
      # 2. иначе
      #    2.a   ищем пользователя по домену, выставляем current_site
      #    2.b   возвращаем 404


      # 1
      if domain.ends_with?("mmm-tasty.ru")
        subdomains = domain.sub(".mmm-tasty.ru", '')

        logger.debug "PCS: subdomains: #{subdomains}"

        # 1.a
        return true if subdomains == 'www' || subdomains == 'mmm-tasty.ru'
        # 1.b
        redirect_to("http://www.mmm-tasty.ru/") and return false if subdomains.count('.') == 0 && User::RESERVED.include?(subdomains)
        # 1.c
        redirect_to("http://#{subdomains.split('.').last}.mmm-tasty.ru") and return false if subdomains.count('.') == 1 && subdomains.split('.').first == 'www'
        # 1.d
        @current_site = User.find_by_url(subdomains, :include => [:tlog_settings]) if subdomains.count('.') == 0
        #   d.1
        # NOTE: не будет работать, потому что ВСЕ запросы будут перенаправляться на домен, а нам этого не нужно
        # redirect_to("http://#{@current_site.domain}/") if @current_site && !@current_site.domain.blank?          
      else
        @current_site = User.find_by_domain(domain)
        @standalone = true if @current_site
      end
      true
    end
  
    def preload_current_user
      # from session
      @current_user = if session[:user_id]
                          begin
                            User.find(session[:user_id])
                          rescue ActiveRecord::RecordNotFound
                            false
                          end
                        else
                          nil
                        end
                      
      logger.info "user #{@current_user.url} from session (id = #{@current_user.id})" if @current_user

      # from tsig
      @current_user ||= if !cookies['tsig'].blank?
                          id, sig = cookies['tsig'].unpack('m').first.unpack('LZ*')
                          user = User.find(id) rescue false
                          if user && user.signature == sig
                            logger.info "user #{user.url} from tsig (id = #{user.id})"
                            session[:user_id] = user.id
                          end
                          user
                        else
                          false
                        end
      true
    end
    
    # 
    def prelaunch_megasecrecy
      return true if cookies['megasecret'] == 'v3' || params[:controller] == 'tlog_feed'
      
      if request.post? && params[:megasecret] == 'lsd'
        cookies['megasecret'] = { :value => 'v3', :expires => 1.year.from_now, :domain => request.domain }
        redirect_to main_url(:host => "www.mmm-tasty.ru")
        return false
      end
  
      render :template => 'globals/prelaunch_megasecrecy', :layout => false
      false
    end
    
    # ошибка 404
    def rescue_action_in_public(exception)
      render :template => 'globals/not_found', :layout => '404'
    end

    # Является ли текущий пользователь владельцем сайта
    def is_owner?
      return true if current_user && current_site && current_user.id == current_site.id
      false
    end
    helper_method :is_owner?

    # Фильтр который требует чтобы пользователь был авторизован прежде чем
    #  мог получить доступ к указанной странице
    def require_current_user
      return true if current_user && current_user.is_a?(User)
      flash[:notice] = 'Вам необходимо зайти чтобы выполнить запрос'
      if request.get?
        session[:redirect_to] = "#{request.protocol}#{request.host_with_port}#{request.request_uri}"
        logger.debug "saving back redirect to: #{session[:redirect_to]}"
      end
      redirect_to login_url(:host => "www.mmm-tasty.ru")
      false
    end
    
    def require_current_site
      return true if current_site && current_site.is_a?(User)
      render :controller => 'tlog', :action => 'tlog_404', :layout => '404', :status => 404
      false
    end
    
    def require_admin
      require_current_user && current_user.is_admin?
    end

    def require_confirmed_current_user
      redirect_to(:host => "www.mmm-tasty.ru", :controller => '/confirm', :action => :required) and return false if (is_owner? && !current_site.is_confirmed?) || (!current_site && current_user && !current_user.is_confirmed?)
      true    
    end
    
    def require_confirmed_current_site
      if !current_site.is_confirmed?          
        render_404("Этот имя занято, но пользователь еще не подтвердил свою регистрацию.<br/>Загляните, пожалуйста, позже.<br/><br/><a href='http://www.mmm-tasty.ru/' rel='follow'>&#x2190; вернуться на главную</a>")
        return false
      end
      true
    end

    def current_user_eq_current_site
      current_user && current_site && current_user.id == current_site.id
    end

    def render_404(text, options = {})
      options[:layout] ||= '404'
      options[:status] ||= 404
      options[:text] = text
      render options
    end

    def host_for_tlog(user=nil, options = {})
      user ||= current_user
      return user.domain if options[:use_domain] && user.is_a?(User) && !user.domain.blank?
      url = user.url rescue user
      "#{url}.mmm-tasty.ru"
    end

    def url_for_tlog(user=nil, options = {})
      page = options.delete(:page) || 0
      fragment = options.delete(:fragment) || nil
      fragment = (page > 0 ? '#' : '/#') + fragment if fragment
      "http://#{host_for_tlog(user, options)}#{page > 0 ? "/page/#{page}" : ''}#{fragment}"
    end
    
    def url_for_entry(entry, options = {})
      is_daylog = current_site.tlog_settings.is_daylog? if current_site
      is_daylog ||= options.delete(:is_daylog)
      user = current_site ? current_site : entry.author

      if is_daylog
        date = @entry.created_at.to_date
        options[:host] = host_for_tlog(user, options)
        options[:year] = date.year
        options[:month] = date.month
        options[:day] = date.mday
        fragment = options.delete(:fragment) || nil
        fragment = ((date == Date.today) ? '/#' : '#') + fragment if fragment 
        (date == Date.today) ? "http://#{options[:host]}#{fragment}" : "#{day_url(options)}#{fragment}"
      else 
        options[:page] = entry.page_for(current_user)
        url_for_tlog(user, options) 
      end
    end
    helper_method :url_for_entry
end