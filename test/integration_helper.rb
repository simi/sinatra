require 'sinatra/base'
require 'rbconfig'
require 'open-uri'
require 'sinatra/runner'

module IntegrationHelper
  class BaseServer < Sinatra::Runner
    extend Enumerable
    attr_accessor :server, :port
    alias name server

    def self.all
      @all ||= []
    end

    def self.each(&block)
      all.each(&block)
    end

    def self.run(server, port)
      new(server, port).run
    end

    def app_file
      File.expand_path('integration/app.rb', __dir__)
    end

    def environment
      "development"
    end

    def initialize(server, port)
      @installed, @pipe, @server, @port = nil, nil, server, port
      Server.all << self
    end

    def run
      return unless installed?
      kill
      @log     = ""
      super
      at_exit { kill }
    end

    def installed?
      return @installed unless @installed.nil?
      s = server == 'HTTP' ? 'net/http/server' : server
      require s
      @installed = true
    rescue LoadError
      warn "#{server} is not installed, skipping integration tests"
      @installed = false
    end

    def command
      @command ||= begin
        cmd = ["APP_ENV=#{environment}", "exec"]
        if RbConfig.respond_to? :ruby
          cmd << RbConfig.ruby.inspect
        else
          file, dir = RbConfig::CONFIG.values_at('ruby_install_name', 'bindir')
          cmd << File.expand_path(file, dir).inspect
        end
        cmd << "-w" unless net_http_server?
        cmd << "-I" << File.expand_path('../lib', __dir__).inspect
        cmd << app_file.inspect << '-s' << server << '-o' << '127.0.0.1' << '-p' << port
        cmd << "-e" << environment.to_s << '2>&1'
        cmd.join " "
      end
    end

    def webrick?
      name.to_s == "webrick"
    end

    def rainbows?
      name.to_s == "rainbows"
    end

    def puma?
      name.to_s == "puma"
    end

    def trinidad?
      name.to_s == "trinidad"
    end

    def net_http_server?
      name.to_s == 'HTTP'
    end

    def warnings
      log.scan(%r[(?:\(eval|lib/sinatra).*warning:.*$])
    end

    def run_test(target, &block)
      retries ||= 3
      target.server = self
      run unless alive?
      target.instance_eval(&block)
    rescue Exception => error
      retries -= 1
      kill
      retries < 0 ? retry : raise(error)
    end
  end

  if RUBY_ENGINE == "jruby"
    class JRubyServer < BaseServer
      def start_vm
        require 'java'
        # Create a new container, set load paths and env
        # SINGLETHREAD means create a new runtime
        vm = org.jruby.embed.ScriptingContainer.new(org.jruby.embed.LocalContextScope::SINGLETHREAD)
        vm.load_paths = [File.expand_path('../lib', __dir__)]
        vm.environment = ENV.merge('APP_ENV' => environment.to_s)

        # This ensures processing of RUBYOPT which activates Bundler
        vm.provider.ruby_instance_config.process_arguments []
        vm.argv = ['-s', server.to_s, '-o', '127.0.0.1', '-p', port.to_s, '-e', environment.to_s]

        # Set stdout/stderr so we can retrieve log
        @pipe = java.io.ByteArrayOutputStream.new
        vm.output = java.io.PrintStream.new(@pipe)
        vm.error  = java.io.PrintStream.new(@pipe)

        Thread.new do
          # Hack to ensure that Kernel#caller has the same info as
          # when run from command-line, for Sinatra::Application.app_file.
          # Also, line numbers are zero-based in JRuby's parser
          vm.provider.runtime.current_context.set_file_and_line(app_file, 0)
          # Run the app
          vm.run_scriptlet org.jruby.embed.PathType::ABSOLUTE, app_file
          # terminate launches at_exit hooks which start server
          vm.terminate
        end
      end

      def run
        return unless installed?
        kill
        @thread  = start_vm
        @started = Time.now
        warn "#{server} up and running on port #{port}" if ping
        at_exit { kill }
      end

      def log
        String.from_java_bytes @pipe.to_byte_array
      end

      def kill
        @thread.kill if @thread
        @thread = nil
      end
    end
    Server = JRubyServer
  else
    Server = BaseServer
  end

  def it(message, &block)
    Server.each do |server|
      next unless server.installed?
      super("with #{server.name}: #{message}") { server.run_test(self, &block) }
    end
  end

  def self.extend_object(obj)
    super

    base_port = 5000 + Process.pid % 100
    Sinatra::Base.server.each_with_index do |server, index|
      Server.run(server, base_port+index)
    end
  end
end
