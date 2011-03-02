require "fileutils"

module Goldberg
  class Project
    attr_reader :url, :name

    def initialize(name)
      @name = name
      @logger = Logger.new
    end

    def self.add(options)
      Project.new(options[:name]).tap do |project|
        project.checkout(options[:url])
      end
    end

    def remove
      FileUtils.rm_rf(path)
    end

    def checkout(url)
      FileUtils.mkdir_p(File.join(Paths.projects, name))
      if !Environment.system("git clone #{url} #{code_path}")
        remove
      end
    rescue
      remove
      raise
    end

    def build_anyway?
      !File.exist?(build_status_path) || !File.exist?("#{build_log_path}") || File.exist?(force_build_path)
    end

    def update
      @logger.info "Checking #{name}"
      run_bundler if run_bundler?
      if !Environment.system_call_output("cd #{code_path} ; git pull").include?('Already up-to-date.') || build_anyway?
        write_build_version
        yield self
      end
    rescue Exception => e
      @logger.error e
    end

    ['build_status', 'force_build', 'build_log', 'change_list', 'code', 'build_number', 'build_version', 'builds', 'change_list'].each do |relative_path|
      define_method "#{relative_path}_path".to_sym do
        path(relative_path)
      end
    end

    def latest_build_number
      Environment.write_file(build_number_path, 0) if !File.exist?(build_number_path)
      Environment.read_file(build_number_path).to_i
    end

    def path(extra = '')
      File.join(Paths.projects, @name, extra)
    end

    def latest_build
      latest_build_path = File.join(path('builds'), latest_build_number.to_s)

      if !File.exist?(latest_build_path)
        return Build.null
      end
      Build.new(latest_build_path)
    end

    def copy_latest_build_to_its_own_folder
      new_build_number = (latest_build_number + 1).to_s
      FileUtils.mkdir_p(File.join(builds_path, new_build_number), :verbose => true)
      FileUtils.cp %w(build_status build_log build_version change_list).map{|basename| File.join(path(basename))}, File.join(builds_path, new_build_number), :verbose => true
      Environment.write_file(build_number_path, new_build_number)
    end

    def build(task = :default)
      write_change_list
      @logger.info "Building #{name}"
      Environment.system("cd #{code_path} ; rake #{task.to_s} 2>&1") do |output, result|
        Environment.write_file(build_log_path, output)
        @logger.info "Build status #{result}"
        Environment.write_file(build_status_path, result)
        File.delete(force_build_path) if File.exist?(force_build_path)
        copy_latest_build_to_its_own_folder
      end
    end

    def self.all
      (Dir.entries(Paths.projects) - ['.', '..']).select{|entry| File.directory?(File.join(Paths.projects, entry))}.map{|entry| Project.new(entry)}
    end

    def status
      if File.exist?(build_status_path)
        Environment.read_file(build_status_path) == 'true'
      else
        nil
      end
    end

    def last_built_at
      latest_build.timestamp
    end

    def id
      name.hash.abs
    end

    def build_log
      Environment.read_file("#{build_log_path}")
    end

    def force_build
      Environment.write_file(force_build_path, '')
      update{ |project| project.build }
    end

    def write_change_list
      changes = Environment.system_call_output("cd #{code_path} ; git diff --name-status #{latest_build.version} #{build_version}")
      Environment.write_file(change_list_path, changes)
    end

    def run_bundler?
      if File.exist?(change_list_path)
        change_list = Environment.read_file(change_list_path)
      end
      latest_build_number == 0 || change_list.include?('Gemfile')  
    end

    def run_bundler
      Environment.system("cd #{code_path} ; bundle install")
    end

    def write_build_version
      current_version = Environment.system_call_output("cd #{code_path} ; git show-ref HEAD --hash")
      Environment.write_file(build_version_path, current_version)
    end

    def build_version
      Environment.read_file(build_version_path).tap do |version|
        version.gsub!(/\n/,'')
      end
    end

    def builds
      Build.all(self)
    end
  end
end

