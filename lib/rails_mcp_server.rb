require "logger"
require "fileutils"
require "forwardable"
require "open3"
require_relative "rails-mcp-server/version"
require_relative "rails-mcp-server/config"
require_relative "rails-mcp-server/utilities/run_process"
require_relative "rails-mcp-server/tools/base_tool"
require_relative "rails-mcp-server/tools/project_info"
require_relative "rails-mcp-server/tools/list_files"
require_relative "rails-mcp-server/tools/get_file"
require_relative "rails-mcp-server/tools/get_routes"
require_relative "rails-mcp-server/tools/analyze_models"
require_relative "rails-mcp-server/tools/get_schema"
require_relative "rails-mcp-server/tools/analyze_controller_views"
require_relative "rails-mcp-server/tools/analyze_environment_config"
require_relative "rails-mcp-server/tools/switch_project"

module RailsMcpServer
  @levels = {debug: Logger::DEBUG, info: Logger::INFO, error: Logger::ERROR}
  @config = Config.setup

  class << self
    extend Forwardable

    attr_reader :config

    def_delegators :@config, :log_level, :log_level=
    def_delegators :@config, :logger, :logger=
    def_delegators :@config, :projects
    def_delegators :@config, :current_project, :current_project=
    def_delegators :@config, :active_project_path, :active_project_path=

    def log(level, message)
      log_level = @levels[level] || Logger::INFO

      @config.logger.add(log_level, message)
    end
  end
  class Error < StandardError; end
end

# rubocop:disable Style/GlobalVars

# Utility functions for Rails operations
def get_directory_structure(path, max_depth: 3, current_depth: 0, prefix: "")
  return "" if current_depth > max_depth || !File.directory?(path)

  # Define ignored directories
  ignored_dirs = [
    ".git", "node_modules", "tmp", "log",
    "storage", "coverage", "public/assets",
    "public/packs", ".bundle", "vendor/bundle",
    "vendor/cache"
  ]

  output = ""
  directories = []
  files = []

  Dir.foreach(path) do |entry|
    next if entry == "." || entry == ".."
    next if ignored_dirs.include?(entry) # Skip ignored directories

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
      end
    end
  rescue => e
    log(:error, "Error parsing .env file #{file_path}: #{e.message}")
  end

  vars
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
# rubocop:enable Style/GlobalVars
