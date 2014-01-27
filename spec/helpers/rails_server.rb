require 'fileutils'
require 'find'
require 'net/http'
require 'uri'

module Spec
  module Helpers
    class RailsServer
      def initialize(name, template_path, options = { })
        @name = name || (raise ArgumentError, "Must specify a name")
        @rails_version = ENV['FORTITUDE_SPECS_RAILS_VERSION'] || options[:rails_version]

        @rails_install_dirname = @name.to_s
        @rails_install_dirname << "-#{@rails_version}" if @rails_version
        @rails_root = File.expand_path(File.join(File.dirname(__FILE__), "../../tmp/spec/system/rails/#{@rails_install_dirname}"))

        @port = 20_000 + rand(10_000)

        @gem_root = File.expand_path(File.join(File.dirname(__FILE__), '../..'))
        @spec_root = File.expand_path(File.join(File.dirname(__FILE__), '..'))
        @template_path = File.expand_path(File.join(@spec_root, template_path))

        @options = options
        @server_pid = nil
      end

      def start!
        unless @server_pid
          do_start!
        end
      end

      def stop!
        if @server_pid
          stop_server!
        end
      end

      def get(path)
        uri_string = "http://localhost:#{@port}/#{path}"
        uri = URI.parse(uri_string)
        data = Net::HTTP.get_response(uri)
        unless data.code.to_s == '200'
          raise "'#{uri_string}' returned #{data.code.inspect}, not 200"
        end
        data.body.strip
      end

      private
      def rails_env
        options[:rails_env] || 'production'
      end

      def do_start!
        with_rails_env do
          setup_directories!

          in_rails_root_parent do
            rails_new!
            update_gemfile!
          end

          in_rails_root do
            Bundler.with_clean_env do
              run_bundle_install!
              splat_template_files!
              start_server!
              verify_server!
            end
          end
        end
      end

      def with_rails_env
        old_rails_env = ENV['RAILS_ENV']
        begin
          ENV['RAILS_ENV'] = old_rails_env
          yield
        ensure
          ENV['RAILS_ENV'] = old_rails_env
        end
      end

      def say(s, newline = true)
        if newline
          $stdout.puts s
        else
          $stdout << s
        end
        $stdout.flush
      end

      def safe_system(cmd, notice = nil, options = { })
        say("#{notice}...", false) if notice

        total_cmd = if options[:background]
          "#{cmd} 2>&1 &"
        else
          "#{cmd} 2>&1"
        end

        output = `#{total_cmd}`
        unless $?.success?
          raise %{Command failed: in directory '#{Dir.pwd}', we tried to run:
% #{total_cmd}
but got result: #{$?.inspect}
and output:
#{output}}
        end
        say "OK" if notice

        output
      end

      def setup_directories!
        return if @directories_setup

        raise Errno::ENOENT, "You must specify a template path that exists; this doesn't: '#{@template_path}'" unless File.directory?(@template_path)
        FileUtils.rm_rf(@rails_root) if File.exist?(@rails_root)
        FileUtils.mkdir_p(@rails_root)

        @directories_setup = true
      end

      def in_rails_root(&block)
        Dir.chdir(@rails_root, &block)
      end

      def in_rails_root_parent(&block)
        Dir.chdir(File.dirname(@rails_root), &block)
      end

      def rails_new!
        # This is a little trick to specify the exact version of Rails you want to create it with...
        # http://stackoverflow.com/questions/379141/specifying-rails-version-to-use-when-creating-a-new-application
        rails_version_spec = @rails_version ? "_#{@rails_version}_" : ""
        safe_system("rails #{rails_version_spec} new #{@name} -d sqlite3 -f -B", "creating a new Rails installation for '#{@name}'")
      end

      def update_gemfile!
        gemfile = File.join(@rails_root, 'Gemfile')
        gemfile_contents = File.read(gemfile)
        gemfile_contents << "\ngem 'fortitude', :path => '#{@gem_root}'\n"
        File.open(gemfile, 'w') { |f| f << gemfile_contents }
      end

      def run_bundle_install!
        safe_system("bundle install --local", "running 'bundle install'")
      end

      def with_env(new_env)
        old_env = { }
        new_env.keys.each { |k| old_env[k] = ENV[k] }

        begin
          set_env(new_env)
          yield
        ensure
          set_env(old_env)
        end
      end

      def set_env(new_env)
        new_env.each do |k,v|
          if v
            ENV[k] = v
          else
            ENV.delete(k)
          end
        end
      end

      def splat_template_files!
        Find.find(@template_path) do |file|
          next unless File.file?(file)

          if file[0..(@template_path.length)] == "#{@template_path}/"
            subpath = file[(@template_path.length + 1)..-1]
          else
            raise "#{file} isn't under #{@template_path}?!?"
          end
          dest_file = File.join(@rails_root, subpath)

          FileUtils.mkdir_p(File.dirname(dest_file))
          FileUtils.cp(file, dest_file)
        end
      end

      def start_server!
        output = File.join(@rails_root, 'log', 'rails-server.out')
        safe_system("rails server -p #{@port} > '#{output}'", "starting 'rails server' on port #{@port}", :background => true)

        server_pid_file = File.join(@rails_root, 'tmp', 'pids', 'server.pid')

        start_time = Time.now
        while Time.now < start_time + 15
          if File.exist?(server_pid_file)
            server_pid = File.read(server_pid_file).strip
            if server_pid =~ /^(\d{1,10})$/i
              @server_pid = Integer(server_pid)
              break
            end
          end
          sleep 0.1
        end
      end

      def verify_server!
        server_verify_url = "http://localhost:#{@port}/basic_rails_system_spec/rails_is_working"
        uri = URI.parse(server_verify_url)
        data = Net::HTTP.get_response(uri)
        unless data.code.to_s == '200'
          raise "'#{server_verify_url}' returned #{data.code.inspect}, not 200"
        end
        result = data.body.strip

        unless result =~ /^Rails\s+version\s*:\s*(\d+\.\d+\.\d+)$/
          raise "'#{server_verify_url}' returned: #{result.inspect}"
        end
        actual_version = $1

        if @rails_version && (actual_version != @rails_version)
          raise "We seem to have spawned the wrong version of Rails; wanted: #{@rails_version.inspect} but got: #{actual_version.inspect}"
        end

        say "Successfully spawned a server running Rails #{actual_version} on port #{@port}."
      end

      def stop_server!
        Process.kill("TERM", @server_pid)
        @server_pid = nil
      end
    end
  end
end