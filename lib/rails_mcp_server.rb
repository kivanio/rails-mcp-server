require "logger"
require "fileutils"
require "forwardable"
require "open3"
require_relative "rails-mcp-server/version"
require_relative "rails-mcp-server/config"
require_relative "rails-mcp-server/extensions/resource_templating"
require_relative "rails-mcp-server/extensions/server_templating"
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
require_relative "rails-mcp-server/tools/load_guide"
require_relative "rails-mcp-server/resources/base_resource"

require_relative "rails-mcp-server/resources/guide_content_formatter"
require_relative "rails-mcp-server/resources/guide_error_handler"
require_relative "rails-mcp-server/resources/guide_file_finder"
require_relative "rails-mcp-server/resources/guide_loader_template"
require_relative "rails-mcp-server/resources/guide_manifest_operations"
require_relative "rails-mcp-server/resources/guide_framework_contract"

require_relative "rails-mcp-server/resources/rails_guides_resource"
require_relative "rails-mcp-server/resources/rails_guides_resources"
require_relative "rails-mcp-server/resources/stimulus_guides_resource"
require_relative "rails-mcp-server/resources/stimulus_guides_resources"
require_relative "rails-mcp-server/resources/turbo_guides_resource"
require_relative "rails-mcp-server/resources/turbo_guides_resources"
require_relative "rails-mcp-server/resources/custom_guides_resource"
require_relative "rails-mcp-server/resources/custom_guides_resources"
require_relative "rails-mcp-server/resources/kamal_guides_resource"
require_relative "rails-mcp-server/resources/kamal_guides_resources"

module RailsMcpServer
  LEVELS = {debug: Logger::DEBUG, info: Logger::INFO, error: Logger::ERROR}
  @config = Config.setup

  class << self
    extend Forwardable

    attr_reader :config

    def_delegators :@config, :log_level, :log_level=
    def_delegators :@config, :logger, :logger=
    def_delegators :@config, :projects
    def_delegators :@config, :current_project, :current_project=
    def_delegators :@config, :active_project_path, :active_project_path=
    def_delegators :@config, :config_dir

    def log(level, message)
      log_level = LEVELS[level] || Logger::INFO

      @config.logger.add(log_level, message)
    end

    # NOTE: This needs to be removed once FastMcp provides official support for URI templating
    # Setup method to initialize FastMcp::Resource extensions
    # Call this after the gem is loaded to enable URI templating
    def setup_resource_extensions!
      Extensions::ResourceExtensionSetup.setup!
    end

    # Check if resource extensions are loaded
    def resource_extensions_loaded?
      Extensions::ResourceExtensionSetup.setup_complete?
    end

    # Setup method to initialize FastMcp::Server extensions
    # This is called automatically by resource extension setup
    def setup_server_extensions!
      Extensions::ServerExtensionSetup.setup!
    end

    # Check if server extensions are loaded
    def server_extensions_loaded?
      Extensions::ServerExtensionSetup.setup_complete?
    end

    # Setup all extensions at once
    def setup_extensions!
      setup_resource_extensions!
      # Server extensions are setup automatically by resource extensions
    end

    # Check if all extensions are loaded
    def extensions_loaded?
      resource_extensions_loaded? && server_extensions_loaded?
    end
  end

  class Error < StandardError; end

  # Auto-setup extensions when the module is loaded
  # This ensures extensions are available immediately
  setup_resource_extensions!
end
