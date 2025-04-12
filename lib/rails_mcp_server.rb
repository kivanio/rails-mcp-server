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

tool "analyze_controller_views" do
  description "Analyze the relationships between controllers, their actions, and corresponding views to understand the application's UI flow."

  argument :controller_name, String, required: false,
    description: "Name of a specific controller to analyze (e.g., 'UsersController' or 'users'). If omitted, all controllers will be analyzed."

  call do |args|
    unless $active_project
      raise "No active project. Please switch to a project first."
    end

    controller_name = args[:controller_name]

    # Find all controllers
    controllers_dir = File.join($active_project_path, "app", "controllers")
    unless File.directory?(controllers_dir)
      raise "Controllers directory not found at app/controllers."
    end

    # Get all controller files
    controller_files = Dir.glob(File.join(controllers_dir, "**", "*_controller.rb"))

    if controller_files.empty?
      raise "No controllers found in the project."
    end

    # If a specific controller was requested, filter the files
    if controller_name
      # Normalize controller name (allow both 'users' and 'UsersController')
      controller_name = "#{controller_name.sub(/_?controller$/i, "").downcase}_controller.rb"
      controller_files = controller_files.select { |f| File.basename(f).downcase == controller_name }

      if controller_files.empty?
        raise "Controller '#{args[:controller_name]}' not found."
      end
    end

    # Parse controllers to extract actions
    controllers_data = {}

    controller_files.each do |file_path|
      file_content = File.read(file_path)
      controller_class = File.basename(file_path, ".rb").gsub(/_controller$/i, "").camelize + "Controller"

      # Extract controller actions (methods that are not private/protected)
      actions = []
      action_matches = file_content.scan(/def\s+([a-zA-Z0-9_]+)/).flatten

      # Find where private/protected begins
      private_index = file_content =~ /^\s*(private|protected)/

      if private_index
        # Get the actions defined before private/protected
        private_content = file_content[private_index..-1]
        private_methods = private_content.scan(/def\s+([a-zA-Z0-9_]+)/).flatten
        actions = action_matches - private_methods
      else
        actions = action_matches
      end

      # Remove Rails controller lifecycle methods
      lifecycle_methods = %w[initialize action_name controller_name params response]
      actions -= lifecycle_methods

      # Get routes mapped to this controller
      routes_cmd = "cd #{$active_project_path} && bin/rails routes -c #{controller_class}"
      routes_output = `#{routes_cmd}`.strip

      routes = {}
      if routes_output && !routes_output.empty?
        routes_output.split("\n").each do |line|
          next if line.include?("(erb):") || line.include?("Prefix") || line.strip.empty?
          parts = line.strip.split(/\s+/)
          if parts.size >= 4
            # Get action name from the rails routes output
            action = parts[1].to_s.strip
            if actions.include?(action)
              verb = parts[0].to_s.strip
              path = parts[2].to_s.strip
              routes[action] = {verb: verb, path: path}
            end
          end
        end
      end

      # Find views for each action
      views_dir = File.join($active_project_path, "app", "views", File.basename(file_path, "_controller.rb"))
      views = {}

      if File.directory?(views_dir)
        actions.each do |action|
          # Look for view templates with various extensions
          view_files = Dir.glob(File.join(views_dir, "#{action}.*"))
          if view_files.any?
            views[action] = {
              templates: view_files.map { |f| f.sub("#{$active_project_path}/", "") },
              partials: []
            }

            # Look for partials used in this template
            view_files.each do |view_file|
              if File.file?(view_file)
                view_content = File.read(view_file)
                # Find render calls with partials
                partial_matches = view_content.scan(/render\s+(?:partial:|:partial\s+=>\s+|:partial\s*=>|partial:)\s*["']([^"']+)["']/).flatten
                views[action][:partials] += partial_matches if partial_matches.any?

                # Find instance variables used in the view
                instance_vars = view_content.scan(/@([a-zA-Z0-9_]+)/).flatten.uniq # rubocop:disable Performance/ChainArrayAllocation
                views[action][:instance_variables] = instance_vars if instance_vars.any?

                # Look for Stimulus controllers
                stimulus_controllers = view_content.scan(/data-controller="([^"]+)"/).flatten.uniq # rubocop:disable Performance/ChainArrayAllocation
                views[action][:stimulus_controllers] = stimulus_controllers if stimulus_controllers.any?
              end
            end
          end
        end
      end

      # Extract instance variables set in the controller action
      instance_vars_in_controller = {}
      actions.each do |action|
        # Find the action method in the controller
        action_match = file_content.match(/def\s+#{action}\b(.*?)(?:(?:def|private|protected|public)\b|\z)/m)
        if action_match && action_match[1]
          action_body = action_match[1]
          # Find instance variable assignments
          vars = action_body.scan(/@([a-zA-Z0-9_]+)\s*=/).flatten.uniq # rubocop:disable Performance/ChainArrayAllocation
          instance_vars_in_controller[action] = vars if vars.any?
        end
      end

      controllers_data[controller_class] = {
        file: file_path.sub("#{$active_project_path}/", ""),
        actions: actions,
        routes: routes,
        views: views,
        instance_variables: instance_vars_in_controller
      }
    rescue => e
      log(:error, "Error parsing controller #{file_path}: #{e.message}")
    end

    # Format the output
    output = []

    controllers_data.each do |controller, data|
      output << "Controller: #{controller}"
      output << "  File: #{data[:file]}"
      output << "  Actions: #{data[:actions].size}"

      data[:actions].each do |action|
        output << "    Action: #{action}"

        # Show route if available
        if data[:routes] && data[:routes][action]
          route = data[:routes][action]
          output << "      Route: [#{route[:verb]}] #{route[:path]}"
        else
          output << "      Route: Not mapped to a route"
        end

        # Show view templates if available
        if data[:views] && data[:views][action]
          view_data = data[:views][action]

          output << "      View Templates:"
          view_data[:templates].each do |template|
            output << "        - #{template}"
          end

          # Show partials
          if view_data[:partials]&.any?
            output << "      Partials Used:"
            view_data[:partials].uniq.each do |partial|
              output << "        - #{partial}"
            end
          end

          # Show Stimulus controllers
          if view_data[:stimulus_controllers]&.any?
            output << "      Stimulus Controllers:"
            view_data[:stimulus_controllers].each do |controller|
              output << "        - #{controller}"
            end
          end

          # Show instance variables used in views
          if view_data[:instance_variables]&.any?
            output << "      Instance Variables Used in View:"
            view_data[:instance_variables].sort.each do |var|
              output << "        - @#{var}"
            end
          end
        else
          output << "      View: No view template found"
        end

        # Show instance variables set in controller
        if data[:instance_variables] && data[:instance_variables][action]
          output << "      Instance Variables Set in Controller:"
          data[:instance_variables][action].sort.each do |var|
            output << "        - @#{var}"
          end
        end

        output << ""
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
# rubocop:enable Style/GlobalVars
