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

    # Use Dir.glob to get matching files
    files = Dir.glob(File.join(full_path, pattern))
      .map { |f| f.sub("#{$active_project_path}/", "") }
      .sort # rubocop:disable Performance/ChainArrayAllocation

    log(:debug, "Found #{files.size} files matching pattern")

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
# rubocop:enable Style/GlobalVars
