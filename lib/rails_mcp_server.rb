#!/usr/bin/env ruby

require "mcp"
require "yaml"
require "logger"
require "json"
require "fileutils"
require_relative "rails-mcp-server/version"

module RailsMcpServer
  class Error < StandardError; end
end

# rubocop:disable Style/GlobalVars
# Initialize configuration
def get_config_dir
  # Use XDG_CONFIG_HOME if set, otherwise use ~/.config
  xdg_config_home = ENV["XDG_CONFIG_HOME"]
  if xdg_config_home && !xdg_config_home.empty?
    File.join(xdg_config_home, "rails-mcp")
  else
    File.join(Dir.home, ".config", "rails-mcp")
  end
end

# Create config directory if it doesn't exist
config_dir = get_config_dir
FileUtils.mkdir_p(File.join(config_dir, "log"))

# Default paths
projects_file = File.join(config_dir, "projects.yml")
log_file = File.join(config_dir, "log", "rails_mcp_server.log")
log_level = :info

# Parse command-line arguments
i = 0
while i < ARGV.length
  case ARGV[i]
  when "--log-level"
    log_level = ARGV[i + 1].to_sym
    i += 2
  else
    i += 1
  end
end

# Initialize logger
$logger = Logger.new(log_file)
$logger.level = Logger.const_get(log_level.to_s.upcase)

# Set a nicer formatter
$logger.formatter = proc do |severity, datetime, progname, msg|
  "[#{datetime.strftime("%Y-%m-%d %H:%M:%S")}] #{severity}: #{msg}\n"
end

def log(level, message)
  levels = {debug: Logger::DEBUG, info: Logger::INFO, warn: Logger::WARN, error: Logger::ERROR, fatal: Logger::FATAL}
  log_level = levels[level] || Logger::INFO
  $logger.add(log_level, message)
end

log(:info, "Starting Rails MCP Server...")
log(:info, "Using config directory: #{config_dir}")

# Create empty projects file if it doesn't exist
unless File.exist?(projects_file)
  log(:info, "Creating empty projects file: #{projects_file}")
  FileUtils.mkdir_p(File.dirname(projects_file))
  File.write(projects_file, "# Rails MCP Projects\n# Format: project_name: /path/to/project\n")
end

# Load projects
projects_file = File.expand_path(projects_file)
projects = {}

if File.exist?(projects_file)
  log(:info, "Loading projects from: #{projects_file}")
  projects = YAML.load_file(projects_file) || {}
  log(:info, "Loaded #{projects.size} projects: #{projects.keys.join(", ")}")
else
  log(:warn, "Projects file not found: #{projects_file}")
end

# Initialize state
$active_project = nil
$active_project_path = nil

# Define MCP server using the mcp-rb DSL
name "rails-mcp-server"
version RailsMcpServer::VERSION

# Utility functions for Rails operations
def get_directory_structure(path, max_depth: 3, current_depth: 0, prefix: "")
  return "" if current_depth > max_depth || !File.directory?(path)

  output = ""
  directories = []
  files = []

  Dir.foreach(path) do |entry|
    next if entry == "." || entry == ".."
    full_path = File.join(path, entry)

    if File.directory?(full_path)
      directories << entry
    else
      files << entry
    end
  end

  directories.sort.each do |dir|
    output << "#{prefix}└── #{dir}/\n"
    full_path = File.join(path, dir)
    output << get_directory_structure(full_path, max_depth: max_depth,
      current_depth: current_depth + 1,
      prefix: "#{prefix}    ")
  end

  files.sort.each do |file|
    output << "#{prefix}└── #{file}\n"
  end

  output
end

def get_file_extension(path)
  case File.extname(path).downcase
  when ".rb"
    "ruby"
  when ".js"
    "javascript"
  when ".html", ".erb"
    "html"
  when ".css"
    "css"
  when ".json"
    "json"
  when ".yml", ".yaml"
    "yaml"
  else
    ""
  end
end

def execute_rails_command(project_path, command)
  full_command = "cd #{project_path} && bin/rails #{command}"
  `#{full_command}`
end

def underscore(string)
  string.gsub("::", "/")
    .gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2')
    .gsub(/([a-z\d])([A-Z])/, '\1_\2')
    .tr("-", "_")
    .downcase
end

# Helper method to parse association options
def parse_association_options(options_str)
  return {} unless options_str

  options = {}
  # Match key: value or :key => value patterns
  options_str.scan(/(:|)[a-z_]+(?:\s*=>|\s*:)\s*[^,]+/).each do |opt|
    key, value = opt.split(/\s*(?:=>|:)\s*/, 2)
    key = key.sub(/^:/, "").strip

    # Clean up the value
    value = value.strip
    value = value.sub(/^:/, "") if value.start_with?(":")
    value = value.gsub(/^["']|["']$/, "") if value.start_with?('"', "'")

    options[key.to_sym] = value
  end

  options
end

# Helper method to parse validation options
def parse_validation_options(options_str)
  parse_association_options(options_str)
end

# Helper method to extract settings from environment files
def extract_env_settings(content)
  settings = {}

  # Match configuration settings
  content.scan(/config\.([a-zA-Z0-9_.]+)\s*=\s*([^#\n]+)/) do |match|
    key = match[0].strip
    value = match[1].strip

    # Clean up the value
    value = value.chomp(";").strip

    settings[key] = value
  end

  settings
end

# Helper method to find ENV variable usage in the codebase
def find_env_vars_in_codebase(project_path)
  env_vars = {}

  # Define directories to search
  search_dirs = [
    File.join(project_path, "app"),
    File.join(project_path, "config"),
    File.join(project_path, "lib")
  ]

  # Define file patterns to search
  file_patterns = ["*.rb", "*.yml", "*.erb", "*.js"]

  search_dirs.each do |dir|
    if File.directory?(dir)
      file_patterns.each do |pattern|
        Dir.glob(File.join(dir, "**", pattern)).each do |file|
          content = File.read(file)

          # Extract ENV variables
          content.scan(/ENV\s*\[\s*['"]([^'"]+)['"]\s*\]/).each do |match|
            env_var = match[0]
            env_vars[env_var] ||= []
            env_vars[env_var] << file.sub("#{project_path}/", "")
          end

          # Also match ENV['VAR'] pattern
          content.scan(/ENV\s*\.\s*\[\s*['"]([^'"]+)['"]\s*\]/).each do |match|
            env_var = match[0]
            env_vars[env_var] ||= []
            env_vars[env_var] << file.sub("#{project_path}/", "")
          end

          # Also match ENV.fetch('VAR') pattern
          content.scan(/ENV\s*\.\s*fetch\s*\(\s*['"]([^'"]+)['"]\s*/).each do |match|
            env_var = match[0]
            env_vars[env_var] ||= []
            env_vars[env_var] << file.sub("#{project_path}/", "")
          end
        rescue => e
          log(:error, "Error reading file #{file}: #{e.message}")
        end
      end
    end
  end

  env_vars
end

# Helper method to parse .env files
def parse_dotenv_file(file_path)
  vars = {}

  begin
    File.readlines(file_path).each do |line| # rubocop:disable Performance/IoReadlines
      # Skip comments and empty lines
      next if line.strip.empty? || line.strip.start_with?("#")

      # Parse KEY=value pattern
      if line =~ /\A([A-Za-z0-9_]+)=(.*)\z/
        key = $1
        # Store just the existence of the variable, not its value
        vars[key] = true

        # Alternative: Store '[REDACTED]' instead of actual value for sensitive keys
        # vars[key] = sensitive_key?(key) ? "[REDACTED]" : $2.gsub(/\A['"]|['"]\z/, "")
      end
    end
  rescue => e
    log(:error, "Error parsing .env file #{file_path}: #{e.message}")
  end

  vars
end

# Helper to identify potentially sensitive keys
def sensitive_key?(key)
  sensitive_patterns = [
    /pass(word)?/i, /secret/i, /key/i, /token/i, /auth/i,
    /cred/i, /sign/i, /access/i, /admin/i
  ]

  sensitive_patterns.any? { |pattern| key.match?(pattern) }
end

# Helper method to parse database.yml
def parse_database_config(file_path)
  config = {}

  begin
    # Simple YAML parsing - not handling ERB
    yaml_content = File.read(file_path)
    yaml_data = YAML.safe_load(yaml_content) || {}

    # Extract environment configurations
    %w[development test production staging].each do |env|
      config[env] = yaml_data[env] if yaml_data[env]
    end
  rescue => e
    log(:error, "Error parsing database.yml: #{e.message}")
  end

  config
end

# Helper method to compare environment settings
def compare_environment_settings(env_settings)
  result = {
    unique_settings: {},
    different_values: {}
  }

  # Get all settings across all environments
  all_settings = env_settings.values.map(&:keys).flatten.uniq # rubocop:disable Performance/ChainArrayAllocation

  # Find settings unique to certain environments
  env_settings.each do |env, settings|
    unique = settings.keys - (all_settings - settings.keys)
    result[:unique_settings][env] = unique if unique.any?
  end

  # Find settings with different values across environments
  all_settings.each do |setting|
    values = {}

    env_settings.each do |env, settings|
      values[env] = settings[setting] if settings[setting]
    end

    # Only include if there are different values
    if values.values.uniq.size > 1
      result[:different_values][setting] = values
    end
  end

  result
end

# Helper method to find missing ENV variables
def find_missing_env_vars(env_vars_in_code, dotenv_vars)
  missing_vars = {}

  # Check each ENV variable used in code
  env_vars_in_code.each do |var, files|
    # Environments where the variable is missing
    missing_in = []

    # Check in each .env file
    if dotenv_vars.empty?
      missing_in << "all environments (no .env files found)"
    else
      dotenv_vars.each do |env_file, vars|
        env_name = env_file.gsub(/^\.env\.?|\.local$/, "")
        env_name = "development" if env_name.empty?

        if !vars.key?(var)
          missing_in << env_name
        end
      end
    end

    missing_vars[var] = missing_in if missing_in.any?
  end

  missing_vars
end

# Helper method to check for security issues
def check_security_configuration(env_settings, database_config)
  findings = []

  # Check for common security settings
  env_settings.each do |env, settings|
    # Check for secure cookies in production
    if env == "production"
      if settings["cookies.secure"] == "false"
        findings << "Production has cookies.secure = false"
      end

      if settings["session_store.secure"] == "false"
        findings << "Production has session_store.secure = false"
      end

      # Force SSL
      if settings["force_ssl"] == "false"
        findings << "Production has force_ssl = false"
      end
    end

    # Check for CSRF protection
    if settings["action_controller.default_protect_from_forgery"] == "false"
      findings << "#{env} has CSRF protection disabled"
    end
  end

  # Check for hardcoded credentials in database.yml
  database_config.each do |env, config|
    if config["username"] && !config["username"].include?("ENV")
      findings << "Database username hardcoded in database.yml for #{env}"
    end

    if config["password"] && !config["password"].include?("ENV")
      findings << "Database password hardcoded in database.yml for #{env}"
    end
  end

  findings
end

# Helper method to determine the current Rails version
def determine_rails_version(project_path)
  gemfile_path = File.join(project_path, "Gemfile")
  gemfile_lock_path = File.join(project_path, "Gemfile.lock")

  # Try to get version from Gemfile.lock first (most accurate)
  if File.exist?(gemfile_lock_path)
    gemfile_lock = File.read(gemfile_lock_path)
    if gemfile_lock =~ /^\s*rails\s+\(([^)]+)\)/
      return $1
    end
  end

  # Fall back to Gemfile
  if File.exist?(gemfile_path)
    gemfile = File.read(gemfile_path)
    if gemfile =~ /gem ['"]rails['"],\s*['"]([^'"]+)['"]/
      return $1
    end
  end

  # If we can't determine the version, check from the application
  version_cmd = "cd #{project_path} && bin/rails runner \"puts Rails.version\" 2>/dev/null"
  version_output = `#{version_cmd}`.strip

  return version_output unless version_output.empty?

  # Default fallback
  "unknown"
end

# Helper method to determine the Ruby version
def determine_ruby_version(project_path)
  ruby_version_file = File.join(project_path, ".ruby-version")

  # Check .ruby-version file
  if File.exist?(ruby_version_file)
    version = File.read(ruby_version_file).strip
    return version if /^\d+\.\d+\.\d+$/.match?(version)
  end

  # Check Gemfile
  gemfile_path = File.join(project_path, "Gemfile")
  if File.exist?(gemfile_path)
    gemfile = File.read(gemfile_path)
    if gemfile =~ /ruby ['"]([^'"]+)['"]/
      return $1
    end
  end

  # Get from current Ruby
  ruby_cmd = "cd #{project_path} && ruby -v"
  ruby_output = `#{ruby_cmd}`.strip

  if ruby_output =~ /ruby (\d+\.\d+\.\d+)/
    return $1
  end

  # Default fallback
  "unknown"
end

# Helper method to get minimum Ruby version for Rails version
def min_ruby_for_rails(rails_version)
  case rails_version
  when /^7\.1/
    "3.1.0"
  when /^7\.0/
    "2.7.0"
  when /^6\.1/
    "2.5.0"
  when /^6\.0/
    "2.5.0"
  when /^5\.2/
    "2.2.2"
  when /^5\.1/
    "2.2.2"
  when /^5\.0/
    "2.2.2"
  else
    "2.0.0" # Default fallback
  end
end

# Helper method to validate Rails version format
def valid_rails_version?(version)
  version =~ /^\d+\.\d+(\.\d+)?$/
end

# Helper method to compare versions
def compare_versions(version1, version2)
  v1_parts = version1.split(".").map(&:to_i)
  v2_parts = version2.split(".").map(&:to_i)

  # Pad with zeros to make equal length
  max_length = [v1_parts.length, v2_parts.length].max
  v1_parts += [0] * (max_length - v1_parts.length)
  v2_parts += [0] * (max_length - v2_parts.length)

  # Compare version components
  v1_parts <=> v2_parts
end

# Helper method to collect project statistics
def collect_project_stats(project_path)
  stats = {
    models: 0,
    controllers: 0,
    views: 0,
    ruby_loc: 0,
    test_files: 0
  }

  # Count models
  models_dir = File.join(project_path, "app", "models")
  if File.directory?(models_dir)
    stats[:models] = Dir.glob(File.join(models_dir, "**", "*.rb")).size
  end

  # Count controllers
  controllers_dir = File.join(project_path, "app", "controllers")
  if File.directory?(controllers_dir)
    stats[:controllers] = Dir.glob(File.join(controllers_dir, "**", "*_controller.rb")).size
  end

  # Count views
  views_dir = File.join(project_path, "app", "views")
  if File.directory?(views_dir)
    stats[:views] = Dir.glob(File.join(views_dir, "**", "*.{erb,haml,slim}")).size
  end

  # Count Ruby LOC (rough estimate)
  ruby_files = Dir.glob(File.join(project_path, "**", "*.rb"))
  stats[:ruby_loc] = ruby_files.sum do |file|
    next 0 unless File.file?(file)
    File.readlines(file).count { |line| line.strip != "" && !line.strip.start_with?("#") } # rubocop:disable Performance/IoReadlines
  end

  # Count test files
  test_dirs = [
    File.join(project_path, "test"),
    File.join(project_path, "spec")
  ]

  test_dirs.each do |dir|
    if File.directory?(dir)
      stats[:test_files] += Dir.glob(File.join(dir, "**", "*.rb")).size
    end
  end

  stats
end

# Helper method to analyze gem compatibility
def analyze_gem_compatibility(current_version, target_version, project_path)
  result = {
    incompatible: {},
    deprecated: {}
  }

  gemfile_path = File.join(project_path, "Gemfile")
  return result unless File.exist?(gemfile_path)

  gemfile = File.read(gemfile_path)

  # Gems that are deprecated or have major changes in newer Rails versions
  deprecated_gems = {
    "coffee-rails" => "Removed from Rails 6. Use JavaScript or Webpacker instead.",
    "sass-rails" => "Consider using cssbundling-rails in Rails 7+",
    "uglifier" => "Consider using jsbundling-rails in Rails 7+",
    "therubyracer" => "No longer necessary with modern JavaScript compilation",
    "jquery-rails" => "jQuery is no longer included by default in Rails 6+",
    "turbolinks" => "Replaced by Turbo in Rails 7+",
    "coffee-script" => "Removed from Rails 6. Use JavaScript instead.",
    "webpacker" => "Deprecated in Rails 7, consider jsbundling-rails"
  }

  # Rails version-specific gem requirements
  version_specific_gems = {
    "7.0" => {
      "importmap-rails" => "Required for JavaScript imports without bundling",
      "stimulus-rails" => "Required for Stimulus integration",
      "turbo-rails" => "Required for Turbo integration",
      "cssbundling-rails" => "Recommended for CSS bundling",
      "jsbundling-rails" => "Recommended for JavaScript bundling"
    },
    "6.1" => {
      "webpacker" => "Required for JavaScript in Rails 6.1"
    },
    "6.0" => {
      "webpacker" => "Required for JavaScript in Rails 6.0",
      "zeitwerk" => "Recommended for code autoloading"
    }
  }

  # Check for deprecated gems
  deprecated_gems.each do |gem_name, reason|
    if /gem ['"]#{gem_name}['"]/.match?(gemfile)
      result[:deprecated][gem_name] = reason
    end
  end

  # Check for missing required gems for target version
  target_version_base = target_version.split(".").first(2).join(".")
  version_specific_gems[target_version_base]&.each do |gem_name, reason|
    unless /gem ['"]#{gem_name}['"]/.match?(gemfile)
      result[:incompatible][gem_name] = {
        current_version: "not installed",
        required_version: "required",
        reason: reason
      }
    end
  end

  # Parse Gemfile.lock for more detailed version info
  gemfile_lock_path = File.join(project_path, "Gemfile.lock")
  if File.exist?(gemfile_lock_path)
    File.read(gemfile_lock_path)

    # Add more gem compatibility checks based on locked versions
    # This would require a more comprehensive database of gem compatibility info
  end

  result
end

# Helper method to find deprecated code patterns
def find_deprecated_patterns(current_version, target_version, project_path, analysis_depth)
  patterns = []

  # Define patterns to search for based on Rails version transition
  deprecated_patterns_db = {
    "5.2-6.0" => [
      {
        pattern: /find_by_(\w+)/,
        files: "**/*.rb",
        category: "ActiveRecord",
        description: "Dynamic finders are deprecated",
        suggestion: "Use find_by(attribute: value) instead"
      },
      {
        pattern: /\.update_attributes/,
        files: "**/*.rb",
        category: "ActiveRecord",
        description: "update_attributes is deprecated",
        suggestion: "Use update instead"
      }
    ],
    "6.0-6.1" => [
      {
        pattern: /config\.autoloader\s*=\s*:classic/,
        files: "config/application.rb",
        category: "Autoloading",
        description: "Classic autoloader is deprecated",
        suggestion: "Use config.autoloader = :zeitwerk"
      }
    ],
    "6.1-7.0" => [
      {
        pattern: /before_validation\s+:([^,]+),\s+:on\s+=>/,
        files: "app/models/**/*.rb",
        category: "ActiveRecord",
        description: ":on option with before_validation is deprecated",
        suggestion: "Use if: or unless: conditions instead"
      },
      {
        pattern: /javascript_include_tag/,
        files: "app/views/**/*.{erb,haml,slim}",
        category: "Asset Pipeline",
        description: "javascript_include_tag is deprecated in Rails 7",
        suggestion: "Use importmap or jsbundling instead"
      },
      {
        pattern: /stylesheet_link_tag/,
        files: "app/views/**/*.{erb,haml,slim}",
        category: "Asset Pipeline",
        description: "stylesheet_link_tag is deprecated in Rails 7 with asset pipeline",
        suggestion: "Use cssbundling instead"
      }
    ],
    "7.0-7.1" => [
      {
        pattern: /config\.active_storage\.replace_on_assign_to_many\s*=\s*false/,
        files: "config/application.rb",
        category: "ActiveStorage",
        description: "replace_on_assign_to_many=false is deprecated",
        suggestion: "The default is now true and should be kept"
      }
    ]
  }

  # Determine which patterns to check based on version transition
  patterns_to_check = []

  # Split the current version and target version
  current_major_minor = current_version.split(".").first(2).join(".")
  target_major_minor = target_version.split(".").first(2).join(".")

  # Get all relevant transition patterns
  deprecated_patterns_db.keys.each do |transition|
    from_version, to_version = transition.split("-")

    if compare_versions(current_major_minor, from_version) <= 0 &&
        compare_versions(target_major_minor, to_version) >= 0
      patterns_to_check.concat(deprecated_patterns_db[transition])
    end
  end

  # For deep analysis, add more detailed patterns
  if analysis_depth == "deep"
    # Add additional patterns for deep analysis
    # These would be more specific and potentially have more false positives
  end

  # Now scan the codebase for these patterns
  patterns_to_check.each do |pattern_def|
    file_pattern = File.join(project_path, pattern_def[:files])

    Dir.glob(file_pattern).each do |file|
      next unless File.file?(file)
      relative_path = file.sub("#{project_path}/", "")

      File.readlines(file).each_with_index do |line, line_num| # rubocop:disable Performance/IoReadlines
        if line&.match?(pattern_def[:pattern])
          patterns << {
            file: relative_path,
            line: line_num + 1,
            code: line.strip,
            category: pattern_def[:category],
            description: pattern_def[:description],
            suggestion: pattern_def[:suggestion]
          }
        end
      end
    end
  end

  patterns
end

# Helper method to analyze configuration changes
def analyze_configuration_changes(current_version, target_version, project_path)
  config_changes = {}

  # Define configuration changes needed based on Rails version
  config_changes_db = {
    "5.2-6.0" => {
      "config/application.rb" => [
        {
          description: "Autoloader config needs to be set (Zeitwerk is default)",
          file_pattern: /config\.autoloader\s*=/,
          expected: "config.autoloader = :zeitwerk",
          suggestion: "Add config.autoloader = :zeitwerk"
        }
      ],
      "config/environments/production.rb" => [
        {
          description: "Cache versioning config needed",
          file_pattern: /config\.cache_store\s*=/,
          suggestion: "Add config.active_record.collection_cache_versioning = true"
        }
      ]
    },
    "6.0-6.1" => {
      "config/application.rb" => [
        {
          description: "ActiveStorage config needs to be updated",
          suggestion: "Add config.active_storage.track_variants = true"
        }
      ]
    },
    "6.1-7.0" => {
      "config/application.rb" => [
        {
          description: "load_defaults should be set to 7.0",
          file_pattern: /config\.load_defaults\s*[\d.]+/,
          expected: "config.load_defaults 7.0",
          suggestion: "Update config.load_defaults to 7.0"
        }
      ],
      "config/environments/production.rb" => [
        {
          description: "Force HTTPS config needed",
          file_pattern: /config\.force_ssl\s*=/,
          expected: "config.force_ssl = true",
          suggestion: "Set config.force_ssl = true for security"
        }
      ]
    },
    "7.0-7.1" => {
      "config/application.rb" => [
        {
          description: "load_defaults should be set to 7.1",
          file_pattern: /config\.load_defaults\s*[\d.]+/,
          expected: "config.load_defaults 7.1",
          suggestion: "Update config.load_defaults to 7.1"
        }
      ]
    }
  }

  # Determine which config changes to check
  changes_to_check = {}

  # Get all relevant transition changes
  config_changes_db.each do |transition, files|
    from_version, to_version = transition.split("-")
    current_major_minor = current_version.split(".").first(2).join(".")
    target_major_minor = target_version.split(".").first(2).join(".")

    if compare_versions(current_major_minor, from_version) <= 0 &&
        compare_versions(target_major_minor, to_version) >= 0
      files.each do |file, file_changes|
        changes_to_check[file] ||= []
        changes_to_check[file].concat(file_changes)
      end
    end
  end

  # Check configuration files for needed changes
  changes_to_check.each do |file, changes|
    full_path = File.join(project_path, file)

    if File.exist?(full_path)
      file_content = File.read(full_path)
      file_changes = []

      changes.each do |change|
        # If there's a file pattern, check if it exists or matches expected value
        if change[:file_pattern] && file_content =~ change[:file_pattern]
          # If it exists but doesn't match expected value
          if change[:expected] && !(file_content =~ /#{Regexp.escape(change[:expected])}/)
            file_changes << change
          end
        else
          # If there's no pattern or the pattern doesn't exist, add change
          file_changes << change
        end
      end

      config_changes[file] = file_changes if file_changes.any?
    else
      # File doesn't exist, add all changes
      config_changes[file] = changes
    end
  end

  config_changes
end

# Helper method to analyze version compatibility
def analyze_version_compatibility(current_version, target_version, project_path)
  # This would analyze overall compatibility based on codebase characteristics
  # For simplicity, we'll just return a placeholder
  {
    overall: "medium"
  }
end

# Helper method to fetch Rails diff summary
def fetch_rails_diff_summary(current_version, target_version)
  # In a real implementation, this would fetch and parse data from railsdiff.org
  # Here we're returning a mock response
  {
    added: [
      "config/initializers/new_framework_defaults_7_0.rb",
      "config/initializers/filter_parameter_logging.rb"
    ],
    modified: [
      "config/application.rb",
      "config/environments/production.rb",
      "config/environments/development.rb",
      "Gemfile"
    ],
    removed: [
      "config/initializers/cookies_serializer.rb"
    ],
    key_files: [
      "config/application.rb",
      "config/environments/production.rb",
      "Gemfile"
    ]
  }
end

# Helper method to estimate upgrade complexity
def estimate_upgrade_complexity(current_version, target_version, project_stats, deprecated_count, config_changes_count, ruby_compatible)
  # Calculate a complexity score
  current_major, current_minor = current_version.split(".").map(&:to_i)
  target_major, target_minor = target_version.split(".").map(&:to_i)

  # Base complexity from version gap
  major_gap = target_major - current_major
  minor_gap = target_minor - current_minor

  version_factor = major_gap * 5 + minor_gap * 2

  # Size factor
  size_factor = 1.0
  if project_stats[:ruby_loc] > 50000
    size_factor = 3.0
  elsif project_stats[:ruby_loc] > 10000
    size_factor = 2.0
  elsif project_stats[:ruby_loc] > 5000
    size_factor = 1.5
  end

  # Complexity factors
  deprecated_factor = if deprecated_count > 50
    2.0
  else
    ((deprecated_count > 20) ? 1.5 : 1.0)
  end
  config_factor = if config_changes_count > 10
    2.0
  else
    ((config_changes_count > 5) ? 1.5 : 1.0)
  end
  ruby_factor = ruby_compatible ? 1.0 : 1.5

  # Calculate final complexity score
  complexity_score = version_factor * size_factor * deprecated_factor * config_factor * ruby_factor

  # Convert to level and estimate
  level = if complexity_score > 30
    "Very High"
  elsif complexity_score > 20
    "High"
  elsif complexity_score > 10
    "Medium"
  elsif complexity_score > 5
    "Low"
  else
    "Very Low"
  end

  # Calculate estimated developer days
  estimate = if level == "Very High"
    "15-20+"
  elsif level == "High"
    "10-15"
  elsif level == "Medium"
    "5-10"
  elsif level == "Low"
    "2-5"
  else
    "1-2"
  end

  {
    level: level,
    score: complexity_score,
    estimate: estimate
  }
end

# Helper method to check if we should use intermediate versions
def should_use_intermediate_versions?(current_version, target_version)
  current_major, current_minor = current_version.split(".").map(&:to_i)
  target_major, target_minor = target_version.split(".").map(&:to_i)

  # If more than one major version jump, suggest intermediate versions
  major_gap = target_major - current_major
  major_gap > 1 || (major_gap == 1 && (target_minor - current_minor) > 1)
end

# Helper method to generate a stepped upgrade path
def generate_upgrade_path(current_version, target_version)
  current_major, current_minor = current_version.split(".").map(&:to_i)
  target_major, target_minor = target_version.split(".").map(&:to_i)

  path = []

  # If current minor is not 0, upgrade to next major.0 first
  if current_minor != 0
    path << "#{current_major + 1}.0"
  end

  # Add intermediate major versions
  ((current_major + 1)...target_major).each do |major|
    path << "#{major}.0"
  end

  # Add target version if not already included
  target_short = "#{target_major}.#{target_minor}"
  path << target_short unless path.last == target_short

  path
end

def sanitize_response(response)
  # Remove non-ASCII characters
  response.encode("UTF-8", invalid: :replace, undef: :replace, replace: "")

  # Alternative method
  response.scrub("")
end

# Define tools using the mcp-rb DSL
tool "switch_project" do
  description "Change the active Rails project to interact with a different codebase. Must be called before using other tools. Available projects are defined in the projects.yml configuration file."

  argument :project_name, String, required: true,
    description: "Name of the project as defined in the projects.yml file (case-sensitive)"

  call do |args|
    project_name = args[:project_name]

    if projects.key?(project_name)
      $active_project = project_name
      $active_project_path = File.expand_path(projects[project_name])
      log(:info, "Switched to project: #{project_name} at path: #{$active_project_path}")
      "Switched to project: #{project_name} at path: #{$active_project_path}"
    else
      log(:warn, "Project not found: #{project_name}")
      raise "Project '#{project_name}' not found. Available projects: #{projects.keys.join(", ")}"
    end
  end
end

tool "get_project_info" do
  description "Retrieve comprehensive information about the current Rails project, including Rails version, directory structure, API-only status, and overall project organization. Useful for initial project exploration and understanding the codebase structure."

  call do |args|
    unless $active_project
      raise "No active project. Please switch to a project first."
    end

    # Get additional project information
    gemfile_path = File.join($active_project_path, "Gemfile")
    gemfile_content = File.exist?(gemfile_path) ? File.read(gemfile_path) : "Gemfile not found"

    # Get Rails version
    rails_version = gemfile_content.match(/gem ['"]rails['"],\s*['"](.+?)['"]/)&.captures&.first || "Unknown"

    # Check if it's an API-only app
    config_application_path = File.join($active_project_path, "config", "application.rb")
    is_api_only = File.exist?(config_application_path) &&
      File.read(config_application_path).include?("config.api_only = true")

    log(:info, "Project info: Rails v#{rails_version}, API-only: #{is_api_only}")

    <<~INFO
      Current project: #{$active_project}
      Path: #{$active_project_path}
      Rails version: #{rails_version}
      API only: #{is_api_only ? "Yes" : "No"}
      
      Project structure:
      #{get_directory_structure($active_project_path, max_depth: 2)}
    INFO
  end
end

tool "list_files" do
  description "List files in the Rails project matching specific criteria. Use this to explore project directories or locate specific file types. If no parameters are provided, lists files in the project root."

  argument :directory, String, required: false,
    description: "Directory path relative to the project root (e.g., 'app/models', 'config'). Leave empty to list files at the root."

  argument :pattern, String, required: false,
    description: "File pattern using glob syntax (e.g., '*.rb' for Ruby files, '*.erb' for ERB templates, '*_controller.rb' for controllers)"

  call do |args|
    unless $active_project
      raise "No active project. Please switch to a project first."
    end

    directory = args[:directory] || ""
    pattern = args[:pattern] || "*"

    full_path = File.join($active_project_path, directory)

    unless File.directory?(full_path)
      raise "Directory '#{directory}' not found in the project."
    end

    # Check if this is a git repository
    is_git_repo = system("cd #{$active_project_path} && git rev-parse --is-inside-work-tree > /dev/null 2>&1")

    if is_git_repo
      log(:debug, "Project is a git repository, using git ls-files")

      # Use git ls-files for tracked files
      relative_dir = directory.empty? ? "" : "#{directory}/"
      git_cmd = "cd #{$active_project_path} && git ls-files --cached --others --exclude-standard #{relative_dir}#{pattern}"

      files = `#{git_cmd}`.split("\n").map(&:strip).sort # rubocop:disable Performance/ChainArrayAllocation
    else
      log(:debug, "Project is not a git repository or git not available, using Dir.glob")

      # Use Dir.glob as fallback
      files = Dir.glob(File.join(full_path, pattern))
        .map { |f| f.sub("#{$active_project_path}/", "") }
        .reject { |file| file.start_with?(".git/", "node_modules/") } # Explicitly filter .git and node_modules directories # rubocop:disable Performance/ChainArrayAllocation
        .sort # rubocop:disable Performance/ChainArrayAllocation
    end

    log(:debug, "Found #{files.size} files matching pattern (respecting .gitignore and ignoring node_modules)")

    "Files in #{directory.empty? ? "project root" : directory} matching '#{pattern}':\n\n#{files.join("\n")}"
  end
end

tool "get_file" do
  description "Retrieve the complete content of a specific file with syntax highlighting. Use this to examine implementation details, configurations, or any text file in the project."

  argument :path, String, required: true,
    description: "File path relative to the project root (e.g., 'app/models/user.rb', 'config/routes.rb'). Use list_files first if you're not sure about the exact path."

  call do |args|
    unless $active_project
      raise "No active project. Please switch to a project first."
    end

    path = args[:path]
    full_path = File.join($active_project_path, path)

    unless File.exist?(full_path)
      raise "File '#{path}' not found in the project."
    end

    content = File.read(full_path)
    log(:debug, "Read file: #{path} (#{content.size} bytes)")

    "File: #{path}\n\n```#{get_file_extension(path)}\n#{content}\n```"
  end
end

tool "get_routes" do
  description "Retrieve all HTTP routes defined in the Rails application with their associated controllers and actions. Equivalent to running 'rails routes' command. This helps understand the API endpoints or page URLs available in the application."

  call do |args|
    unless $active_project
      raise "No active project. Please switch to a project first."
    end

    # Execute the Rails routes command
    routes_output = execute_rails_command($active_project_path, "routes")
    log(:debug, "Routes command completed, output size: #{routes_output.size} bytes")

    "Rails Routes:\n\n```\n#{routes_output}\n```"
  end
end

tool "get_models" do
  description "Retrieve detailed information about Active Record models in the project. When called without parameters, lists all model files. When a specific model is specified, returns its schema, associations (has_many, belongs_to, has_one), and complete source code."

  argument :model_name, String, required: false,
    description: "Class name of a specific model to get detailed information for (e.g., 'User', 'Product'). Use CamelCase, not snake_case. If omitted, returns a list of all models."

  call do |args|
    unless $active_project
      raise "No active project. Please switch to a project first."
    end

    model_name = args[:model_name]

    if model_name
      log(:info, "Getting info for specific model: #{model_name}")

      # Check if the model file exists
      model_file = File.join($active_project_path, "app", "models", "#{underscore(model_name)}.rb")
      unless File.exist?(model_file)
        log(:warn, "Model file not found: #{model_name}")
        raise "Model '#{model_name}' not found."
      end

      log(:debug, "Reading model file: #{model_file}")

      # Get the model file content
      model_content = File.read(model_file)

      # Try to get schema information
      log(:debug, "Executing Rails runner to get schema information")
      schema_info = execute_rails_command(
        $active_project_path,
        "runner \"puts #{model_name}.column_names\""
      )

      # Try to get associations
      associations = []
      if model_content.include?("has_many")
        has_many = model_content.scan(/has_many\s+:(\w+)/).flatten
        associations << "Has many: #{has_many.join(", ")}" unless has_many.empty?
      end

      if model_content.include?("belongs_to")
        belongs_to = model_content.scan(/belongs_to\s+:(\w+)/).flatten
        associations << "Belongs to: #{belongs_to.join(", ")}" unless belongs_to.empty?
      end

      if model_content.include?("has_one")
        has_one = model_content.scan(/has_one\s+:(\w+)/).flatten
        associations << "Has one: #{has_one.join(", ")}" unless has_one.empty?
      end

      log(:debug, "Found #{associations.size} associations for model: #{model_name}")

      # Format the output
      <<~INFO
        Model: #{model_name}
        
        Schema:
        #{schema_info}
        
        Associations:
        #{associations.empty? ? "None found" : associations.join("\n")}
        
        Model Definition:
        ```ruby
        #{model_content}
        ```
      INFO
    else
      log(:info, "Listing all models")

      # List all models
      models_dir = File.join($active_project_path, "app", "models")
      unless File.directory?(models_dir)
        raise "Models directory not found."
      end

      # Get all .rb files in the models directory and its subdirectories
      model_files = Dir.glob(File.join(models_dir, "**", "*.rb"))
        .map { |f| f.sub("#{models_dir}/", "").sub(/\.rb$/, "") }
        .sort # rubocop:disable Performance/ChainArrayAllocation

      log(:debug, "Found #{model_files.size} model files")

      "Models in the project:\n\n#{model_files.join("\n")}"
    end
  end
end

tool "get_schema" do
  description "Retrieve database schema information for the Rails application. Without parameters, returns all tables and the complete schema.rb. With a table name, returns detailed column information including data types, constraints, and foreign keys for that specific table."

  argument :table_name, String, required: false,
    description: "Database table name to get detailed schema information for (e.g., 'users', 'products'). Use snake_case, plural form. If omitted, returns complete database schema."

  call do |args|
    unless $active_project
      raise "No active project. Please switch to a project first."
    end

    table_name = args[:table_name]

    if table_name
      log(:info, "Getting schema for table: #{table_name}")

      # Execute the Rails schema command for a specific table
      schema_output = execute_rails_command(
        $active_project_path,
        "runner \"require 'active_record'; puts ActiveRecord::Base.connection.columns('#{table_name}').map{|c| [c.name, c.type, c.null, c.default].inspect}.join('\n')\""
      )

      if schema_output.strip.empty?
        raise "Table '#{table_name}' not found or has no columns."
      end

      # Parse the column information
      columns = schema_output.strip.split("\n").map do |column_info|
        eval(column_info) # This is safe because we're generating the string ourselves # rubocop:disable Security/Eval
      end

      # Format the output
      formatted_columns = columns.map do |name, type, nullable, default|
        "#{name} (#{type})#{nullable ? ", nullable" : ""}#{default ? ", default: #{default}" : ""}"
      end

      output = <<~SCHEMA
        Table: #{table_name}
        
        Columns:
        #{formatted_columns.join("\n")}
      SCHEMA

      # Try to get foreign keys
      begin
        fk_output = execute_rails_command(
          $active_project_path,
          "runner \"require 'active_record'; puts ActiveRecord::Base.connection.foreign_keys('#{table_name}').map{|fk| [fk.from_table, fk.to_table, fk.column, fk.primary_key].inspect}.join('\n')\""
        )

        unless fk_output.strip.empty?
          foreign_keys = fk_output.strip.split("\n").map do |fk_info|
            eval(fk_info) # This is safe because we're generating the string ourselves # rubocop:disable Security/Eval
          end

          formatted_fks = foreign_keys.map do |from_table, to_table, column, primary_key|
            "#{column} -> #{to_table}.#{primary_key}"
          end

          output += <<~FK
            
            Foreign Keys:
            #{formatted_fks.join("\n")}
          FK
        end
      rescue => e
        log(:warn, "Error fetching foreign keys: #{e.message}")
      end

      output
    else
      log(:info, "Getting full schema")

      # Execute the Rails schema:dump command
      # First, check if we need to create the schema file
      schema_file = File.join($active_project_path, "db", "schema.rb")
      unless File.exist?(schema_file)
        log(:info, "Schema file not found, attempting to generate it")
        execute_rails_command($active_project_path, "db:schema:dump")
      end

      if File.exist?(schema_file)
        # Read the schema file
        schema_content = File.read(schema_file)

        # Try to get table list
        tables_output = execute_rails_command(
          $active_project_path,
          "runner \"require 'active_record'; puts ActiveRecord::Base.connection.tables.sort.join('\n')\""
        )

        tables = tables_output.strip.split("\n")

        <<~SCHEMA
          Database Schema
          
          Tables:
          #{tables.join("\n")}
          
          Schema Definition:
          ```ruby
          #{schema_content}
          ```
        SCHEMA

      else
        # If we can't get the schema file, try to get the table list
        tables_output = execute_rails_command(
          $active_project_path,
          "runner \"require 'active_record'; puts ActiveRecord::Base.connection.tables.sort.join('\n')\""
        )

        if tables_output.strip.empty?
          raise "Could not retrieve schema information. Try running 'rails db:schema:dump' in your project first."
        end

        tables = tables_output.strip.split("\n")

        <<~SCHEMA
          Database Schema
          
          Tables:
          #{tables.join("\n")}
          
          Note: Full schema definition is not available. Run 'rails db:schema:dump' to generate the schema.rb file.
        SCHEMA
      end
    end
  end
end

# tool "analyze_controller_views" do
#   description "Analyze the relationships between controllers, their actions, and corresponding views to understand the application's UI flow."
#
#   argument :controller_name, String, required: false,
#     description: "Name of a specific controller to analyze (e.g., 'UsersController' or 'users'). If omitted, all controllers will be analyzed."
#
#   call do |args|
#     unless $active_project
#       raise "No active project. Please switch to a project first."
#     end
#
#     controller_name = args[:controller_name]
#
#     # Find all controllers
#     controllers_dir = File.join($active_project_path, "app", "controllers")
#     unless File.directory?(controllers_dir)
#       raise "Controllers directory not found at app/controllers."
#     end
#
#     # Get all controller files
#     controller_files = Dir.glob(File.join(controllers_dir, "**", "*_controller.rb"))
#
#     if controller_files.empty?
#       raise "No controllers found in the project."
#     end
#
#     # If a specific controller was requested, filter the files
#     if controller_name
#       # Normalize controller name (allow both 'users' and 'UsersController')
#       controller_name = "#{controller_name.sub(/_?controller$/i, "").downcase}_controller.rb"
#       controller_files = controller_files.select { |f| File.basename(f).downcase == controller_name }
#
#       if controller_files.empty?
#         raise "Controller '#{args[:controller_name]}' not found."
#       end
#     end
#
#     # Parse controllers to extract actions
#     controllers_data = {}
#
#     controller_files.each do |file_path|
#       file_content = File.read(file_path)
#       controller_class = File.basename(file_path, ".rb").gsub(/_controller$/i, "").camelize + "Controller"
#
#       # Extract controller actions (methods that are not private/protected)
#       actions = []
#       action_matches = file_content.scan(/def\s+([a-zA-Z0-9_]+)/).flatten
#
#       # Find where private/protected begins
#       private_index = file_content =~ /^\s*(private|protected)/
#
#       if private_index
#         # Get the actions defined before private/protected
#         private_content = file_content[private_index..-1]
#         private_methods = private_content.scan(/def\s+([a-zA-Z0-9_]+)/).flatten
#         actions = action_matches - private_methods
#       else
#         actions = action_matches
#       end
#
#       # Remove Rails controller lifecycle methods
#       lifecycle_methods = %w[initialize action_name controller_name params response]
#       actions -= lifecycle_methods
#
#       # Get routes mapped to this controller
#       routes_cmd = "cd #{$active_project_path} && bin/rails routes -c #{controller_class}"
#       routes_output = `#{routes_cmd}`.strip
#
#       routes = {}
#       if routes_output && !routes_output.empty?
#         routes_output.split("\n").each do |line|
#           next if line.include?("(erb):") || line.include?("Prefix") || line.strip.empty?
#           parts = line.strip.split(/\s+/)
#           if parts.size >= 4
#             # Get action name from the rails routes output
#             action = parts[1].to_s.strip
#             if actions.include?(action)
#               verb = parts[0].to_s.strip
#               path = parts[2].to_s.strip
#               routes[action] = {verb: verb, path: path}
#             end
#           end
#         end
#       end
#
#       # Find views for each action
#       views_dir = File.join($active_project_path, "app", "views", File.basename(file_path, "_controller.rb"))
#       views = {}
#
#       if File.directory?(views_dir)
#         actions.each do |action|
#           # Look for view templates with various extensions
#           view_files = Dir.glob(File.join(views_dir, "#{action}.*"))
#           if view_files.any?
#             views[action] = {
#               templates: view_files.map { |f| f.sub("#{$active_project_path}/", "") },
#               partials: []
#             }
#
#             # Look for partials used in this template
#             view_files.each do |view_file|
#               if File.file?(view_file)
#                 view_content = File.read(view_file)
#                 # Find render calls with partials
#                 partial_matches = view_content.scan(/render\s+(?:partial:|:partial\s+=>\s+|:partial\s*=>|partial:)\s*["']([^"']+)["']/).flatten
#                 views[action][:partials] += partial_matches if partial_matches.any?
#
#                 # Find instance variables used in the view
#                 instance_vars = view_content.scan(/@([a-zA-Z0-9_]+)/).flatten.uniq # rubocop:disable Performance/ChainArrayAllocation
#                 views[action][:instance_variables] = instance_vars if instance_vars.any?
#
#                 # Look for Stimulus controllers
#                 stimulus_controllers = view_content.scan(/data-controller="([^"]+)"/).flatten.uniq # rubocop:disable Performance/ChainArrayAllocation
#                 views[action][:stimulus_controllers] = stimulus_controllers if stimulus_controllers.any?
#               end
#             end
#           end
#         end
#       end
#
#       # Extract instance variables set in the controller action
#       instance_vars_in_controller = {}
#       actions.each do |action|
#         # Find the action method in the controller
#         action_match = file_content.match(/def\s+#{action}\b(.*?)(?:(?:def|private|protected|public)\b|\z)/m)
#         if action_match && action_match[1]
#           action_body = action_match[1]
#           # Find instance variable assignments
#           vars = action_body.scan(/@([a-zA-Z0-9_]+)\s*=/).flatten.uniq # rubocop:disable Performance/ChainArrayAllocation
#           instance_vars_in_controller[action] = vars if vars.any?
#         end
#       end
#
#       controllers_data[controller_class] = {
#         file: file_path.sub("#{$active_project_path}/", ""),
#         actions: actions,
#         routes: routes,
#         views: views,
#         instance_variables: instance_vars_in_controller
#       }
#     rescue => e
#       log(:error, "Error parsing controller #{file_path}: #{e.message}")
#     end
#
#     # Format the output
#     output = []
#
#     controllers_data.each do |controller, data|
#       output << "Controller: #{controller}"
#       output << "  File: #{data[:file]}"
#       output << "  Actions: #{data[:actions].size}"
#
#       data[:actions].each do |action|
#         output << "    Action: #{action}"
#
#         # Show route if available
#         if data[:routes] && data[:routes][action]
#           route = data[:routes][action]
#           output << "      Route: [#{route[:verb]}] #{route[:path]}"
#         else
#           output << "      Route: Not mapped to a route"
#         end
#
#         # Show view templates if available
#         if data[:views] && data[:views][action]
#           view_data = data[:views][action]
#
#           output << "      View Templates:"
#           view_data[:templates].each do |template|
#             output << "        - #{template}"
#           end
#
#           # Show partials
#           if view_data[:partials]&.any?
#             output << "      Partials Used:"
#             view_data[:partials].uniq.each do |partial|
#               output << "        - #{partial}"
#             end
#           end
#
#           # Show Stimulus controllers
#           if view_data[:stimulus_controllers]&.any?
#             output << "      Stimulus Controllers:"
#             view_data[:stimulus_controllers].each do |controller|
#               output << "        - #{controller}"
#             end
#           end
#
#           # Show instance variables used in views
#           if view_data[:instance_variables]&.any?
#             output << "      Instance Variables Used in View:"
#             view_data[:instance_variables].sort.each do |var|
#               output << "        - @#{var}"
#             end
#           end
#         else
#           output << "      View: No view template found"
#         end
#
#         # Show instance variables set in controller
#         if data[:instance_variables] && data[:instance_variables][action]
#           output << "      Instance Variables Set in Controller:"
#           data[:instance_variables][action].sort.each do |var|
#             output << "        - @#{var}"
#           end
#         end
#
#         output << ""
#       end
#
#       output << "-------------------------"
#     end
#
#     output.join("\n")
#   end
# end

tool "visualize_associations" do
  description "Create a comprehensive visualization of model relationships, helping developers understand complex data associations between Active Record models."

  argument :model_name, String, required: false,
    description: "Class name of a specific model to analyze (e.g., 'User', 'Product'). If omitted, all models will be analyzed."

  call do |args|
    unless $active_project
      raise "No active project. Please switch to a project first."
    end

    model_name = args[:model_name]

    # Find all models
    models_dir = File.join($active_project_path, "app", "models")
    unless File.directory?(models_dir)
      raise "Models directory not found at app/models."
    end

    # Get all model files
    model_files = Dir.glob(File.join(models_dir, "**", "*.rb"))
    model_files = model_files.reject { |f| File.basename(f).start_with?("concerns/") }

    if model_files.empty?
      raise "No models found in the project."
    end

    # If a specific model was requested, filter the files
    if model_name
      # Convert CamelCase to snake_case for file matching
      model_file_name = "#{underscore(model_name)}.rb"
      model_files = model_files.select { |f| File.basename(f) == model_file_name }

      if model_files.empty?
        raise "Model '#{model_name}' not found."
      end
    end

    # Read schema information to understand foreign keys
    schema_cmd = "cd #{$active_project_path} && bin/rails runner \"puts ActiveRecord::Base.connection.tables.map{|t| [t, ActiveRecord::Base.connection.columns(t).map{|c| [c.name, c.type]}.select{|n,_| n.end_with?('_id')}.map{|n,t| n}.join(',')].join(':')}\" 2>/dev/null"
    schema_output = `#{schema_cmd}`.strip

    table_foreign_keys = {}
    if schema_output && !schema_output.empty?
      schema_output.split("\n").each do |line|
        table, foreign_keys = line.split(":")
        table_foreign_keys[table] = foreign_keys.split(",") if foreign_keys && !foreign_keys.empty?
      end
    end

    # Get index information to identify which foreign keys are indexed
    indexes_cmd = "cd #{$active_project_path} && bin/rails runner \"puts ActiveRecord::Base.connection.tables.map{|t| [t, ActiveRecord::Base.connection.indexes(t).map{|i| i.columns}.flatten.join(',')].join(':')}\" 2>/dev/null"
    indexes_output = `#{indexes_cmd}`.strip

    table_indexes = {}
    if indexes_output && !indexes_output.empty?
      indexes_output.split("\n").each do |line|
        table, indexes = line.split(":")
        table_indexes[table] = indexes.split(",") if indexes && !indexes.empty?
      end
    end

    # Parse models to extract associations
    models_data = {}

    model_files.each do |file_path|
      file_content = File.read(file_path)
      model_class_name = File.basename(file_path, ".rb").camelize

      # Extract class definition to handle namespaced models
      class_def = file_content.match(/class\s+([A-Za-z0-9:]+)/)
      if class_def && class_def[1]
        model_class_name = class_def[1]
      end

      associations = {
        belongs_to: [],
        has_many: [],
        has_one: [],
        has_and_belongs_to_many: []
      }

      # Extract belongs_to associations
      file_content.scan(/belongs_to\s+(?::|\s+)([:\w]+)(?:,\s*(.+))?/).each do |match|
        name = match[0].sub(/^:/, "")
        options = parse_association_options(match[1]) if match[1]
        associations[:belongs_to] << {name: name, options: options || {}}
      end

      # Extract has_many associations
      file_content.scan(/has_many\s+(?::|\s+)([:\w]+)(?:,\s*(.+))?/).each do |match|
        name = match[0].sub(/^:/, "")
        options = parse_association_options(match[1]) if match[1]
        associations[:has_many] << {name: name, options: options || {}}
      end

      # Extract has_one associations
      file_content.scan(/has_one\s+(?::|\s+)([:\w]+)(?:,\s*(.+))?/).each do |match|
        name = match[0].sub(/^:/, "")
        options = parse_association_options(match[1]) if match[1]
        associations[:has_one] << {name: name, options: options || {}}
      end

      # Extract has_and_belongs_to_many associations
      file_content.scan(/has_and_belongs_to_many\s+(?::|\s+)([:\w]+)(?:,\s*(.+))?/).each do |match|
        name = match[0].sub(/^:/, "")
        options = parse_association_options(match[1]) if match[1]
        associations[:has_and_belongs_to_many] << {name: name, options: options || {}}
      end

      # Extract validations
      validations = []
      file_content.scan(/validates(?:_[a-z_]+)?\s+(?::|\s+)([:\w,\s]+)(?:,\s*(.+))?/).each do |match|
        fields = match[0].sub(/^:/, "").split(/,\s*/).map { |f| f.sub(/^:/, "") }
        options = parse_validation_options(match[1]) if match[1]
        validations << {fields: fields, options: options || {}}
      end

      # Get table name
      table_name = model_class_name.underscore.tr("/", "_").pluralize
      table_name_pattern = /self\.table_name\s*=\s*["']([^"']+)["']/
      if file_content&.match?(table_name_pattern)
        table_name = file_content.match(table_name_pattern)[1]
      end

      # Check if model has STI (Single Table Inheritance)
      sti_type = nil
      inheritance_pattern = /< (\w+)/
      if file_content&.match?(inheritance_pattern)
        parent_class = file_content.match(inheritance_pattern)[1]
        sti_type = parent_class unless ["ApplicationRecord", "ActiveRecord::Base"].include?(parent_class) # rubocop:disable Performance/CollectionLiteralInLoop
      end

      # Store model data
      models_data[model_class_name] = {
        file: file_path.sub("#{$active_project_path}/", ""),
        table_name: table_name,
        associations: associations,
        validations: validations,
        sti_type: sti_type
      }
    rescue => e
      log(:error, "Error parsing model #{file_path}: #{e.message}")
    end

    # Enrich association data with foreign key and index information
    models_data.each do |model_class, data|
      # Check belongs_to associations for foreign keys and indexes
      data[:associations][:belongs_to].each do |association|
        foreign_key = association[:options][:foreign_key] || "#{association[:name]}_id"

        # Get target class name
        target_class = association[:options][:class_name] || association[:name].camelize

        # Check if foreign key exists in the schema
        if table_foreign_keys[data[:table_name]]&.include?(foreign_key)
          association[:foreign_key_exists] = true

          # Check if the foreign key is indexed
          association[:indexed] = table_indexes[data[:table_name]]&.include?(foreign_key) || false
        else
          association[:foreign_key_exists] = false
        end

        association[:target_class] = target_class
      end
    end

    # Format the output
    output = []

    models_data.each do |model_class, data|
      output << "Model: #{model_class}"
      output << "  File: #{data[:file]}"
      output << "  Table: #{data[:table_name]}"

      # Show inheritance if present
      if data[:sti_type]
        output << "  Inherits from: #{data[:sti_type]} (Single Table Inheritance)"
      end

      # Show associations
      if data[:associations][:belongs_to].any?
        output << "  Belongs To:"
        data[:associations][:belongs_to].each do |assoc|
          options_str = []
          options_str << (assoc[:options][:optional] ? "optional: true" : "required")
          options_str << "foreign_key: #{assoc[:options][:foreign_key]}" if assoc[:options][:foreign_key]
          options_str << "class_name: #{assoc[:options][:class_name]}" if assoc[:options][:class_name]
          options_str << "polymorphic: true" if assoc[:options][:polymorphic]

          # Add foreign key info
          if assoc[:foreign_key_exists]
            key_info = assoc[:indexed] ? "indexed" : "not indexed"
            options_str << "foreign_key exists (#{key_info})"
          else
            options_str << "foreign_key not found in schema" unless assoc[:options][:polymorphic]
          end

          output << "    - #{assoc[:name]} → #{assoc[:target_class]} (#{options_str.join(", ")})"
        end
      end

      if data[:associations][:has_many].any?
        output << "  Has Many:"
        data[:associations][:has_many].each do |assoc|
          options_str = []
          options_str << "dependent: :#{assoc[:options][:dependent]}" if assoc[:options][:dependent]
          options_str << "foreign_key: #{assoc[:options][:foreign_key]}" if assoc[:options][:foreign_key]
          options_str << "class_name: #{assoc[:options][:class_name]}" if assoc[:options][:class_name]
          options_str << "through: :#{assoc[:options][:through]}" if assoc[:options][:through]
          options_str << "polymorphic: true" if assoc[:options][:as]

          # Add relationship description
          target_class = assoc[:options][:class_name] || assoc[:name].singularize.camelize
          relationship = options_str.any? ? " (#{options_str.join(", ")})" : ""

          output << "    - #{assoc[:name]} → #{target_class}#{relationship}"
        end
      end

      if data[:associations][:has_one].any?
        output << "  Has One:"
        data[:associations][:has_one].each do |assoc|
          options_str = []
          options_str << "dependent: :#{assoc[:options][:dependent]}" if assoc[:options][:dependent]
          options_str << "foreign_key: #{assoc[:options][:foreign_key]}" if assoc[:options][:foreign_key]
          options_str << "class_name: #{assoc[:options][:class_name]}" if assoc[:options][:class_name]
          options_str << "through: :#{assoc[:options][:through]}" if assoc[:options][:through]

          # Add relationship description
          target_class = assoc[:options][:class_name] || assoc[:name].camelize
          relationship = options_str.any? ? " (#{options_str.join(", ")})" : ""

          output << "    - #{assoc[:name]} → #{target_class}#{relationship}"
        end
      end

      if data[:associations][:has_and_belongs_to_many].any?
        output << "  Has And Belongs To Many:"
        data[:associations][:has_and_belongs_to_many].each do |assoc|
          options_str = []
          options_str << "join_table: #{assoc[:options][:join_table]}" if assoc[:options][:join_table]
          options_str << "class_name: #{assoc[:options][:class_name]}" if assoc[:options][:class_name]

          # Add relationship description
          target_class = assoc[:options][:class_name] || assoc[:name].singularize.camelize
          relationship = options_str.any? ? " (#{options_str.join(", ")})" : ""

          output << "    - #{assoc[:name]} → #{target_class}#{relationship}"
        end
      end

      # Show validations
      if data[:validations].any?
        output << "  Validations:"
        data[:validations].each do |validation|
          fields_str = validation[:fields].join(", ")
          options_str = validation[:options].map { |k, v| "#{k}: #{v}" }.join(", ")

          output << "    - #{fields_str} (#{options_str})"
        end
      end

      output << "-------------------------"
    end

    output.join("\n")
  end
end

tool "analyze_environment_config" do
  description "Analyze environment configurations to identify inconsistencies, security issues, and missing variables across environments."

  call do |args|
    unless $active_project
      raise "No active project. Please switch to a project first."
    end

    # Check for required directories and files
    env_dir = File.join($active_project_path, "config", "environments")
    unless File.directory?(env_dir)
      raise "Environment configuration directory not found at config/environments."
    end

    # Initialize data structures
    env_files = {}
    env_settings = {}

    # 1. Parse environment files
    Dir.glob(File.join(env_dir, "*.rb")).each do |file|
      env_name = File.basename(file, ".rb")
      env_files[env_name] = file
      env_content = File.read(file)

      # Extract settings from environment files
      env_settings[env_name] = extract_env_settings(env_content)
    end

    # 2. Find ENV variable usage across the codebase
    env_vars_in_code = find_env_vars_in_codebase($active_project_path)

    # 3. Check for .env files and their variables
    dotenv_files = {}
    dotenv_vars = {}

    # Common .env file patterns
    dotenv_patterns = [
      ".env",
      ".env.development",
      ".env.test",
      ".env.production",
      ".env.local",
      ".env.development.local",
      ".env.test.local",
      ".env.production.local"
    ]

    dotenv_patterns.each do |pattern|
      file_path = File.join($active_project_path, pattern)
      if File.exist?(file_path)
        dotenv_files[pattern] = file_path
        dotenv_vars[pattern] = parse_dotenv_file(file_path)
      end
    end

    # 4. Check credentials files
    credentials_files = {}
    credentials_key_file = File.join($active_project_path, "config", "master.key")
    credentials_file = File.join($active_project_path, "config", "credentials.yml.enc")

    if File.exist?(credentials_file)
      credentials_files["credentials.yml.enc"] = credentials_file
    end

    # Environment-specific credentials files
    Dir.glob(File.join($active_project_path, "config", "credentials", "*.yml.enc")).each do |file|
      env_name = File.basename(file, ".yml.enc")
      credentials_files["credentials/#{env_name}.yml.enc"] = file
    end

    # 5. Check database configuration
    database_config_file = File.join($active_project_path, "config", "database.yml")
    database_config = {}

    if File.exist?(database_config_file)
      database_config = parse_database_config(database_config_file)
    end

    # 6. Generate findings

    # 6.1. Compare environment settings
    env_diff = compare_environment_settings(env_settings)

    # 6.2. Find missing ENV variables
    missing_env_vars = find_missing_env_vars(env_vars_in_code, dotenv_vars)

    # 6.3. Check for potential security issues
    security_findings = check_security_configuration(env_settings, database_config)

    # Format the output
    output = []

    # Environment files summary
    output << "Environment Configuration Analysis"
    output << "=================================="
    output << ""
    output << "Environment Files:"
    env_files.each do |env, file|
      output << "  - #{env}: #{file.sub("#{$active_project_path}/", "")}"
    end
    output << ""

    # Environment variables summary
    output << "Environment Variables Usage:"
    output << "  Total unique ENV variables found in codebase: #{env_vars_in_code.keys.size}"
    output << ""

    # Missing ENV variables
    if missing_env_vars.any?
      output << "Missing ENV Variables:"
      missing_env_vars.each do |env_var, environments|
        output << "  - #{env_var}: Used in codebase but missing in #{environments.join(", ")}"
      end
    else
      output << "All ENV variables appear to be defined in at least one .env file."
    end
    output << ""

    # Environment differences
    if env_diff[:unique_settings].any?
      output << "Environment-Specific Settings:"
      env_diff[:unique_settings].each do |env, settings|
        output << "  #{env}:"
        settings.each do |setting|
          output << "    - #{setting}"
        end
      end
      output << ""
    end

    if env_diff[:different_values].any?
      output << "Settings with Different Values Across Environments:"
      env_diff[:different_values].each do |setting, values|
        output << "  #{setting}:"
        values.each do |env, value|
          output << "    - #{env}: #{value}"
        end
      end
      output << ""
    end

    # Credentials files
    output << "Credentials Management:"
    if credentials_files.any?
      output << "  Encrypted credentials files found:"
      credentials_files.each do |name, file|
        output << "    - #{name}"
      end

      output << if File.exist?(credentials_key_file)
        "  Master key file exists (config/master.key)"
      else
        "  Warning: No master.key file found. Credentials are likely managed through RAILS_MASTER_KEY environment variable."
      end
    else
      output << "  No encrypted credentials files found. The application may be using ENV variables exclusively."
    end
    output << ""

    # Database configuration
    output << "Database Configuration:"
    if database_config.any?
      database_config.each do |env, config|
        output << "  #{env}:"
        # Show connection details without exposing passwords
        if config["adapter"]
          output << "    - Adapter: #{config["adapter"]}"
        end
        if config["host"] && config["host"] != "localhost" && config["host"] != "127.0.0.1"
          output << "    - Host: #{config["host"]}"
        end
        if config["database"]
          output << "    - Database: #{config["database"]}"
        end

        # Check for credentials in database.yml
        if config["username"] && !config["username"].include?("ENV")
          output << "    - Warning: Database username hardcoded in database.yml"
        end
        if config["password"] && !config["password"].include?("ENV")
          output << "    - Warning: Database password hardcoded in database.yml"
        end
      end
    else
      output << "  Could not parse database configuration."
    end
    output << ""

    # Security findings
    if security_findings.any?
      output << "Security Configuration Findings:"
      security_findings.each do |finding|
        output << "  - #{finding}"
      end
      output << ""
    end

    output.join("\n")
  end
end

tool "rails_upgrade_assistant" do
  description "Analyze compatibility with newer Rails versions, highlight deprecated code patterns, and suggest modern alternatives."

  argument :target_version, String, required: false,
    description: "Target Rails version to analyze compatibility with (e.g., '6.1', '7.0'). Defaults to latest stable version."

  argument :analysis_depth, String, required: false,
    description: "Depth of analysis: 'basic' (quick scan) or 'deep' (comprehensive analysis). Defaults to 'basic'."

  call do |args|
    unless $active_project
      raise "No active project. Please switch to a project first."
    end

    # Default values
    target_version = args[:target_version] || "7.0"
    analysis_depth = args[:analysis_depth] || "basic"

    log(:info, "Starting Rails upgrade analysis to version #{target_version} with #{analysis_depth} analysis")

    # Determine current Rails version
    current_version = determine_rails_version($active_project_path)
    log(:info, "Current Rails version: #{current_version}")

    # Validate versions
    if !valid_rails_version?(target_version)
      raise "Invalid target Rails version: #{target_version}. Please use format like '6.1' or '7.0'."
    end

    if compare_versions(current_version, target_version) >= 0
      raise "Target version (#{target_version}) must be higher than current version (#{current_version})."
    end

    # Perform the analysis
    output = []
    output << "Rails Upgrade Analysis: #{current_version} -> #{target_version}"
    output << "=" * output.first.length
    output << ""

    # Basic info about the project
    project_stats = collect_project_stats($active_project_path)
    output << "Project Statistics:"
    output << "  - Models: #{project_stats[:models]}"
    output << "  - Controllers: #{project_stats[:controllers]}"
    output << "  - Views: #{project_stats[:views]}"
    output << "  - Lines of Ruby code: #{project_stats[:ruby_loc]}"
    output << "  - Test files: #{project_stats[:test_files]}"
    output << ""

    # Analyze Rails version compatibility
    analyze_version_compatibility(current_version, target_version, $active_project_path)

    # Check Ruby version compatibility
    ruby_version = determine_ruby_version($active_project_path)
    min_ruby_version = min_ruby_for_rails(target_version)
    ruby_compatible = compare_versions(ruby_version, min_ruby_version) >= 0

    output << "Ruby Compatibility:"
    output << "  - Current Ruby version: #{ruby_version}"
    output << "  - Required Ruby version for Rails #{target_version}: #{min_ruby_version}#{ruby_compatible ? " (compatible)" : " (upgrade required)"}"
    output << ""

    # Gem compatibility analysis
    gem_analysis = analyze_gem_compatibility(current_version, target_version, $active_project_path)
    output << "Gem Compatibility Analysis:"
    output << "  - #{gem_analysis[:incompatible].size} gems require version updates"
    output << "  - #{gem_analysis[:deprecated].size} gems have been deprecated"
    if gem_analysis[:incompatible].any?
      output << "  "
      output << "  Gems requiring updates:"
      gem_analysis[:incompatible].each do |gem_name, details|
        output << "    - #{gem_name}: current #{details[:current_version]}, required #{details[:required_version]}"
      end
    end
    if gem_analysis[:deprecated].any?
      output << "  "
      output << "  Deprecated gems:"
      gem_analysis[:deprecated].each do |gem_name, alternative|
        output << "    - #{gem_name}: #{alternative}"
      end
    end
    output << ""

    # Analyze deprecated code patterns
    deprecated_patterns = find_deprecated_patterns(current_version, target_version, $active_project_path, analysis_depth)
    output << "Deprecated Code Patterns:"
    output << "  Found #{deprecated_patterns.size} instances of deprecated patterns"

    if deprecated_patterns.any?
      output << "  "
      deprecated_patterns.group_by { |p| p[:category] }.each do |category, patterns|
        output << "  #{category} (#{patterns.size}):"
        patterns.first(5).each do |pattern|
          output << "    - #{pattern[:file]}:#{pattern[:line]} - #{pattern[:description]}"
          output << "      #{pattern[:suggestion]}" if pattern[:suggestion]
        end
        if patterns.size > 5
          output << "    - ... and #{patterns.size - 5} more instances"
        end
      end
    end
    output << ""

    # Configuration file analysis
    config_changes = analyze_configuration_changes(current_version, target_version, $active_project_path)
    output << "Configuration Changes Required:"
    output << "  - #{config_changes.size} configuration files need updates"

    if config_changes.any?
      output << "  "
      config_changes.each do |file, changes|
        output << "  #{file}:"
        changes.first(3).each do |change|
          output << "    - #{change[:description]}"
        end
        if changes.size > 3
          output << "    - ... and #{changes.size - 3} more changes"
        end
      end
    end
    output << ""

    # RailsDiff comparison
    if analysis_depth == "deep"
      begin
        rails_diff = fetch_rails_diff_summary(current_version, target_version)
        output << "RailsDiff Analysis (from railsdiff.org):"
        output << "  Changes detected in default Rails app between versions:"
        output << "  - #{rails_diff[:added].size} files added"
        output << "  - #{rails_diff[:modified].size} files modified"
        output << "  - #{rails_diff[:removed].size} files removed"
        output << "  "
        output << "  Key files to review:"
        rails_diff[:key_files].each do |file|
          output << "    - #{file}"
        end
        output << "  "
        output << "  View complete diff at: https://railsdiff.org/#{current_version}/#{target_version}"
      rescue => e
        output << "RailsDiff analysis failed: #{e.message}"
      end
      output << ""
    end

    # Generate upgrade complexity estimate
    complexity = estimate_upgrade_complexity(
      current_version,
      target_version,
      project_stats,
      deprecated_patterns.size,
      config_changes.size,
      ruby_compatible
    )

    # Display overall complexity and upgrade plan
    output << "Upgrade Complexity: #{complexity[:level]} (estimated #{complexity[:estimate]} developer days)"
    output << ""

    # Generate recommended upgrade path if spanning multiple major versions
    if should_use_intermediate_versions?(current_version, target_version)
      upgrade_path = generate_upgrade_path(current_version, target_version)
      output << "Recommended Upgrade Path:"
      upgrade_path.each_with_index do |version, index|
        output << "  #{index + 1}. Upgrade to Rails #{version}"
      end
      output << ""
    end

    # Final recommendations and next steps
    output << "Next Steps:"
    output << "  1. #{ruby_compatible ? "Ruby version is compatible" : "Upgrade Ruby to at least #{min_ruby_version}"}"
    output << "  2. Update Gemfile dependencies"
    output << "  3. Address deprecated code patterns"
    output << "  4. Update configuration files"
    output << "  5. Run test suite after each major change"
    output << ""
    output << "For detailed guidance on Rails #{target_version} upgrade process, see:"
    output << "  - Official Rails Upgrade Guide: https://guides.rubyonrails.org/upgrading_ruby_on_rails.html"
    output << "  - RailsDiff: https://railsdiff.org/#{current_version}/#{target_version}"

    # Return the formatted output
    sanitize_response(output.join("\n"))
  end
end
# rubocop:enable Style/GlobalVars
