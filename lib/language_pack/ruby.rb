require "tmpdir"
require "rubygems"
require "language_pack"
require "language_pack/base"

# base Ruby Language Pack. This is for any base ruby app.
class LanguagePack::Ruby < LanguagePack::Base
  LIBYAML_VERSION     = "0.1.4"
  LIBYAML_PATH        = "libyaml-#{LIBYAML_VERSION}"
  BUNDLER_VERSION     = "2.0.2"
  BUNDLER_GEM_PATH    = "bundler-#{BUNDLER_VERSION}"
  NODE_VERSION        = "0.4.7"
  NODE_JS_BINARY_PATH = "node-#{NODE_VERSION}"
  RUBY_PKG_EXTENSION  = "tar.bz2"
  BIN_DIR             = "bin"
  VENDOR_DIR          = "vendor"

  # detects if this is a valid Ruby app
  # @return [Boolean] true if it's a Ruby app
  def self.use?
    File.exist?("Gemfile")
  end

  def name
    "Ruby"
  end

  def default_addons
  end

  def default_config_vars
    vars = {
      "LANG"     => "en_US.UTF-8",
      "PATH"     => default_path,
      "GEM_PATH" => slug_vendor_bundler,
      "GEM_HOME" => "/tmp/gems"
    }
  end

  def default_process_types
    {
      "rake"    => "bundle exec rake",
      "console" => "bundle exec irb"
    }
  end

  def compile
    Dir.chdir(build_path)
    remove_vendor_bundle
    install_ruby
    setup_language_pack_environment
    setup_profiled
    allow_git do
      # install_language_pack_gems
      build_bundler
      run_assets_precompile_rake_task
    end
  end

private

  # install the vendored ruby
  # @return [Boolean] true if it installs the vendored ruby and false otherwise
  def install_ruby
    FileUtils.mkdir_p(VENDOR_DIR)
    run("cp -R #{build_ruby_path} #{VENDOR_DIR}/#{ruby_version}")
    topic "cp -R #{build_ruby_path} #{VENDOR_DIR}/#{ruby_version}"
    topic `ls /opt/ruby/3.0.2/bin`

    FileUtils.mkdir_p BIN_DIR
    Dir["#{slug_vendor_ruby}/bin/*"].each do |bin_in_vendor|
      run("ln -s ../#{bin_in_vendor} #{BIN_DIR}/")
    end

    topic "Using Ruby version: #{ruby_version} (test: #{`#{BIN_DIR}/ruby -v`})"
    true
  end

  # runs bundler to install the dependencies
  def build_bundler
    log("bundle") do
      puts run("#{slug_vendor_ruby}/bin/gem install bundler -v=#{BUNDLER_VERSION} --no-document")

      bundle_without = ENV["BUNDLE_WITHOUT"] || "development:test"
      bundle_command = "#{slug_vendor_ruby}/bin/bundle install --without #{bundle_without} --path #{VENDOR_DIR}/bundle --binstubs #{BIN_DIR}/"

      unless File.exist?("Gemfile.lock")
        error "Gemfile.lock is required. Please run \"bundle install\" locally\nand commit your Gemfile.lock."
      end

      # using --deployment is preferred if we can
      bundle_command += " --deployment"
      cache_load ".bundle"

      version = run("env #{slug_vendor_ruby}/bin/bundle version").strip
      topic("Installing dependencies using bundler #{version}")

      cache_load "#{VENDOR_DIR}/bundle"

      bundler_output = ""
      Dir.mktmpdir("libyaml-") do |tmpdir|
        libyaml_dir = "#{tmpdir}/#{LIBYAML_PATH}"
        install_libyaml(libyaml_dir)

        # need to setup compile environment for the psych gem
        yaml_include   = File.expand_path("#{libyaml_dir}/include")
        yaml_lib       = File.expand_path("#{libyaml_dir}/lib")
        pwd            = run("pwd").chomp
        # we need to set BUNDLE_CONFIG and BUNDLE_GEMFILE for
        # codon since it uses bundler.
        env_vars       = "env BUNDLE_GEMFILE=#{pwd}/Gemfile BUNDLE_CONFIG=#{pwd}/.bundle/config CPATH=#{yaml_include}:$CPATH CPPATH=#{yaml_include}:$CPPATH LIBRARY_PATH=#{yaml_lib}:$LIBRARY_PATH"
        puts "Running: #{bundle_command}"
        bundler_output << pipe("#{env_vars} #{bundle_command} --no-clean 2>&1")

      end

      if $?.success?
        log "bundle", :status => "success"
        puts "Cleaning up the bundler cache."
        run "bundle clean"
        cache_store ".bundle"
        cache_store "#{VENDOR_DIR}/bundle"

        # Keep gem cache out of the slug
        FileUtils.rm_rf("#{slug_vendor_bundler}/cache")
      else
        log "bundle", :status => "failure"
        error_message = "Failed to install gems via Bundler."
        error error_message
      end
    end
  end

  # the base PATH environment variable to be used
  # @return [String] the resulting PATH
  def default_path
    "bin:#{slug_vendor_bundler}/bin:/usr/local/bin:/usr/bin:/bin"
  end

  # the relative path to the bundler directory of gems
  # @return [String] resulting path
  def slug_vendor_bundler
    # @slug_vendor_bundler ||= run(%q(ruby -e "require 'rbconfig';puts \"vendor/bundle/#{RUBY_ENGINE}/#{RbConfig::CONFIG['ruby_version']}\"")).chomp
    @slug_vendor_bundler ||= File.join(VENDOR_DIR, "bundle", "ruby", ruby_version_number.sub(/\d+$/, '0'))
  end

  # the relative path to the vendored ruby directory
  # @return [String] resulting path
  def slug_vendor_ruby
    "#{VENDOR_DIR}/#{ruby_version}"
  end

  # the absolute path of the build ruby to use during the buildpack
  # @return [String] resulting path
  def build_ruby_path
    "/opt/ruby/#{ruby_version_number}"
  end

  # fetch the ruby version from bundler
  # @return [String, nil] returns the ruby version if detected or nil if none is detected
  def ruby_version
    return @ruby_version if @ruby_version_run

    @ruby_version_run = true
    @ruby_version = lockfile_parser.ruby_version.chomp.sub(/p\d+$/, '').sub(' ', '-')
    return @ruby_version if @ruby_version =~ /(\w+-)?\d\.\d\.\d/

    if ENV['RUBY_VERSION'] && (@ruby_version == "No ruby version specified" || @ruby_version.nil?)
      @ruby_version = ENV['RUBY_VERSION']
      @ruby_version_env_var = true
    else
      bootstrap_bundler do |bundler_path|
        @ruby_version = run_stdout("GEM_PATH=#{bundler_path} #{bundler_path}/bin/bundle platform --ruby").chomp.sub(/p\d+$/, '')
      end
    end

    @ruby_version
  end

  def ruby_version_number
    ruby_version.split(/[- ]/).last
  end

  # bootstraps bundler so we can pull the ruby version
  def bootstrap_bundler(&block)
    Dir.mktmpdir("bundler-") do |tmpdir|
      Dir.chdir(tmpdir) do
        run("curl #{VENDOR_URL}/#{BUNDLER_GEM_PATH}.tar.gz | tar -xz --strip-components=1")
      end

      yield tmpdir
    end
  end

  # sets up the environment variables for the build process
  def setup_language_pack_environment
    setup_ruby_install_env

    config_vars = default_config_vars.each do |key, value|
      ENV[key] ||= value
    end
    ENV["GEM_HOME"] = slug_vendor_bundler
    ENV["PATH"]     = "#{ruby_install_binstub_path}:#{config_vars["PATH"]}"
  end

  # sets up the profile.d script for this buildpack
  def setup_profiled
    set_env_default  "GEM_PATH", "$HOME/#{slug_vendor_bundler}"
    set_env_default  "LANG",     "en_US.UTF-8"
    set_env_override "PATH",     "$HOME/bin:$HOME/#{slug_vendor_bundler}/bin:$PATH"
  end

  # find the ruby install path for its binstubs during build
  # @return [String] resulting path or empty string if ruby is not vendored
  def ruby_install_binstub_path
    #puts "ruby_install_binstub_path: #{slug_vendor_ruby}/bin"
    @ruby_install_binstub_path ||= "#{slug_vendor_ruby}/bin"
  end

  # find the ruby install path for its binstubs during build
  # @return [String] resulting path or empty string if ruby is not vendored
  def ruby_install_libstub_path
    #puts "ruby_install_libstub_path: #{slug_vendor_ruby}/lib"
    @ruby_install_libstub_path ||= "#{slug_vendor_ruby}/lib"
  end

  # setup the environment so we can use the vendored ruby
  def setup_ruby_install_env
    #puts "setup_ruby_install_env: #{ruby_install_binstub_path}"
    ENV["PATH"] = "#{ruby_install_binstub_path}:#{ENV["PATH"]}"
    #puts "setup_ruby_install_env: #{ruby_install_libstub_path}"
    ENV["LD_LIBRARY_PATH"] = "#{File.expand_path(ruby_install_libstub_path)}:#{ENV["LD_LIBRARY_PATH"]}"
  end

  # detects if a gem is in the bundle.
  # @param [String] name of the gem in question
  # @return [String, nil] if it finds the gem, it will return the line from bundle show or nil if nothing is found.
  def gem_is_bundled?(gem)
    @bundler_gems ||= lockfile_parser.specs.map(&:name)
    @bundler_gems.include?(gem)
  end

  # add bundler to the load path
  # @note it sets a flag, so the path can only be loaded once
  def add_bundler_to_load_path
    return if @bundler_loadpath
    $: << File.expand_path(Dir["#{slug_vendor_bundler}/lib"].first)
    @bundler_loadpath = true
  end

  # setup the lockfile parser
  # @return [Bundler::LockfileParser] a Bundler::LockfileParser
  def lockfile_parser
    # add_bundler_to_load_path
    require "bundler"
    @lockfile_parser ||= Bundler::LockfileParser.new(File.read("Gemfile.lock"))
  end

  # detects if a rake task is defined in the app
  # @param [String] the task in question
  # @return [Boolean] true if the rake task is defined in the app
  def rake_task_defined?(task)
    run("env PATH=$PATH bundle exec rake #{task} --dry-run") && $?.success?
  end

  # executes the block with GIT_DIR environment variable removed since it can mess with the current working directory git thinks it's in
  # @param [block] block to be executed in the GIT_DIR free context
  def allow_git(&blk)
    git_dir = ENV.delete("GIT_DIR") # can mess with bundler
    blk.call
    ENV["GIT_DIR"] = git_dir
  end

  # decides if we need to install the node.js binary
  # @note execjs will blow up if no JS RUNTIME is detected and is loaded.
  # @return [Array] the node.js binary path if we need it or an empty Array
  def add_node_js_binary
    gem_is_bundled?('execjs') ? [NODE_JS_BINARY_PATH] : []
  end

  # list of default gems to vendor into the slug
  # @return [Array] resulting list of gems
  def vendored_gems
    [BUNDLER_GEM_PATH]
  end

  # installs vendored gems into the slug
  def install_language_pack_gems
    FileUtils.mkdir_p(slug_vendor_bundler)
    Dir.chdir(slug_vendor_bundler) do |dir|
      vendored_gems.each do |g|
        puts run("curl #{VENDOR_URL}/#{g}.tar.gz | tar -xz --strip-components=1")
      end
      # Dir["bin/*"].each {|path| run("chmod 755 #{path}") }
    end
  end

  # install libyaml into the LP to be referenced for psych compilation
  # @param [String] tmpdir to store the libyaml files
  def install_libyaml(dir)
    FileUtils.mkdir_p dir
    Dir.chdir(dir) do |dir|
      run("curl #{VENDOR_URL}/#{LIBYAML_PATH}.tgz -s -o - | tar xzf -")
    end
  end

  # remove `vendor/bundle` that comes from the git repo
  # in case there are native ext.
  # users should be using `bundle pack` instead.
  # https://github.com/heroku/heroku-buildpack-ruby/issues/21
  def remove_vendor_bundle
    if File.exists?("vendor/bundle")
      topic "WARNING:  Removing `vendor/bundle`."
      puts  "Checking in `vendor/bundle` is not supported. Please remove this directory"
      puts  "and add it to your .gitignore. To vendor your gems with Bundler, use"
      puts  "`bundle pack` instead."
      FileUtils.rm_rf("vendor/bundle")
    end
  end

  def run_assets_precompile_rake_task
    if rake_task_defined?("assets:precompile")
      require 'benchmark'

      topic("Running: rake assets:precompile")
      time = Benchmark.realtime { pipe("env PATH=$PATH:bin bundle exec rake assets:precompile 2>&1") }
      if $?.success?
        puts "Asset precompilation completed (#{"%.2f" % time}s)"
      end
    end
  end
end
