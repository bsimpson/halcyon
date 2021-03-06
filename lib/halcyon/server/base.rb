#--
#  Created by Matt Todd on 2007-12-14.
#  Copyright (c) 2007. All rights reserved.
#++

%w(logger json).each {|dep|require dep}

module Halcyon
  class Server
    
    DEFAULT_OPTIONS = {
      :root => Dir.pwd,
      :logger => Logger.new(STDOUT),
      :log_file => '/var/log/halcyon.{app}.log',
      :log_level => 'info',
      :log_format => proc{|s,t,p,m|"#{s} [#{t.strftime("%Y-%m-%d %H:%M:%S")}] (#{$$}) #{p} :: #{m}\n"},
      :logger => Logger.new(STDOUT),
      :allow_from => :all,
      :fail_hard => false
    }
    
    class Base
      
      #--
      # Request Handling
      #++
      
      def call(env)
        @time_started = Time.now
        
        # collect env information, create request and response objects, prep for dispatch
        # puts env.inspect if $debug # request information (huge)
        @env = env
        @res = Rack::Response.new
        @req = Rack::Request.new(env)
        
        # handle filtering unwanted requests
        acceptable_request!
        
        # set the User Agent (to be nice to anything to needs accurate information from it)
        @res['Content-Type'] = "application/json"
        @res['User-Agent'] = "JSON/#{JSON::VERSION} Compatible (en-US) Halcyon::Server/#{Halcyon.version}"
        
        # add the logger to the @env instance variable for global access if for
        # some reason the environment needs to be passed outside of the
        # instance
        @env['halcyon.logger'] = @logger
        
        # pre run hook
        before_run(Time.now - @time_started) if respond_to? :before_run
        
        # prepare route and provide it for callers
        route = Router.route(@env)
        @env['halcyon.route'] = route
        
        # dispatch (safely)
        begin
          @res.write(run(route).to_json)
        rescue Exception => e
          @logger.error "#{e.message}\n\t" << e.backtrace.join("\t")
          @res.write({:status => 500, :body => 'Internal Server Error'}.to_json)
          abort "#{e.message}\n\t" << e.backtrace.join("\t") if @config[:fail_hard]
        end
        
        # post run hook
        after_run(Time.now - @time_started) if respond_to? :after_run
        
        @time_finished = Time.now - @time_started
        
        # logs access in the following format: [200] / => index (0.0029s;343.79req/s)
        req_time, req_per_sec = ((@time_finished*1e4).round.to_f/1e4), (((1.0/@time_finished)*1e2).round.to_f/1e2)
        @logger.info "[#{@res.status}] #{@env['REQUEST_URI']} => #{route[:module].to_s}#{((route[:module].nil?) ? "" : "::")}#{route[:action]} (#{req_time}s;#{req_per_sec}req/s)"
        
        # finish request
        @res.finish
      end
      
      def run(route)
        # make sure the request meets our expectations
        acceptable_request! unless !@options[:restrict_requests] || $debug || $test
        
        # pull params
        @params = route.reject{|key, val| [:action, :module].include? key}
        @params.merge!(query_params)
        
        # pre call hook
        before_call if respond_to? :before_call
        
        # handle module actions differently than non-module actions
        if route[:module].nil?
          # call action
          res = send(route[:action])
        else
          # call module action
          mod = self.dup
          mod.instance_eval(&(@@modules[route[:module].to_sym]))
          res = mod.send(route[:action])
        end
        
        # after call hook
        after_call if respond_to? :after_call
        
        @params = {}
        
        res
      rescue Halcyon::Exceptions::Base => e
        @logger.warn "#{uri} => #{e.error}"
        # handles all content error exceptions
        @res.status = e.status
        {:status => e.status, :body => e.error}
      end
      
      # Filters unacceptable requests depending on the configuration of the
      # <tt>:allow_from</tt> option.
      # Acceptable values include:
      # 
      #   <tt>:all</tt>:: allow every request to go through
      #   <tt>:halcyon_clients</tt>:: only allow Halcyon clients
      #   <tt>:local</tt>:: do not allow for requests from an outside host
      def acceptable_request!
        case @config[:allow_from]
        when :all
          # allow every request to go through
        when :halcyon_clients
          # only allow Halcyon clients
          raise Exception::Forbidden.new unless @env['USER_AGENT'] =~ /JSON\/1\.1\.\d+ Compatible \(en-US\) Halcyon::Client\(\d+\.\d+\.\d+\)/
        when :local
          # do not allow for requests from an outside host
          raise Exceptions::Forbidden.new unless ['localhost', '127.0.0.1', '0.0.0.0'].member? @env["REMOTE_ADDR"]
        else
          warn "Unrecognized allow_from configuration value (#{@config[:allow_from].to_s}); use all, halcyon_clients, or local."
        end
      end
      
      #--
      # Initialization and setup
      #++
      
      def initialize(options = {})
        # save configuration options
        @config = DEFAULT_OPTIONS.merge(options)
        @config[:app] ||= self.class.to_s
        
        @logger = @config[:logger]

        @logger.info "Starting up..."
        
        # call startup callback if defined
        startup if respond_to? :startup
        
        # log ready state
        @logger.info "Started. Listening on #{@config[:port]}."
        
        # trap signals to die (when killed by the user) gracefully
        finalize =  Proc.new do
          @logger.info "Shutting down #{$$}."
          # clean_up
          exit
        end
        # http://en.wikipedia.org/wiki/Signal_%28computing%29
        %w(INT KILL TERM QUIT HUP).each{|sig|trap(sig, finalize)}
        
        # listen for USR1 signals and toggle debugging accordingly
        trap("USR1") do
          if $debug
            # disable_debugging
          else
            # enable_debugging
          end
        end
      end
      
      def self.route
        if block_given?
          Router.prepare do |router|
            Router.default_to yield(router) || {:action => 'not_found'}
          end
        else
          abort "Halcyon::Server::Base.route expects a block to define routes."
        end
      end
      
      def self.method_missing(name, *params, &proc)
        @@modules ||= {}
        @@modules[name] = proc
      end
      
      #--
      # Properties and shortcuts
      #++
      
      def standard_response(body = 'OK')
        {:status => 200, :body => body}
      end
      alias_method :success, :standard_response
      alias_method :ok, :standard_response
      
      def not_found(body = 'Not Found')
        body = 'Not Found' if body.is_a?(Hash) && body.empty?
        raise Exceptions::NotFound.new(404, body)
      end
      
      def params
        @params
      end
      
      def query_params
        @env['QUERY_STRING'].split(/&/).inject({}){|h,kp| k,v = kp.split(/=/); h[k] = v; h}.to_mash
      end
      
      def uri
        # special parsing is done to remove the protocol, host, and port that
        # some Handlers leave in there. (Fixes inconsistencies.)
        URI.parse(@env['REQUEST_URI'] || @env['PATH_INFO']).path
      end
      
      def method
        @env['REQUEST_METHOD'].downcase.to_sym
      end
      
      def post
        @req.POST.to_mash
      end
      
      def get
        @req.GET.to_mash
      end
      
    end
    
  end
end
