module RailsMcpServer
  class ProjectInfo < BaseTool
    tool_name "project_info"

    description "Retrieve comprehensive information about the current Rails project, including Rails version, directory structure, API-only status, and overall project organization. Useful for initial project exploration and understanding the codebase structure."

    def call
      unless current_project
        message = "No active project. Please switch to a project first."
        log(:warn, message)

        return message
      end

      # Get additional project information
      gemfile_path = File.join(active_project_path, "Gemfile")
      gemfile_content = File.exist?(gemfile_path) ? File.read(gemfile_path) : "Gemfile not found"

      # Get Rails version
      rails_version = gemfile_content.match(/gem ['"]rails['"],\s*['"](.+?)['"]/)&.captures&.first || "Unknown"

      # Check if it's an API-only app
      config_application_path = File.join(active_project_path, "config", "application.rb")
      is_api_only = File.exist?(config_application_path) &&
        File.read(config_application_path).include?("config.api_only = true")

      log(:info, "Project info: Rails v#{rails_version}, API-only: #{is_api_only}")

      <<~INFO
        Current project: #{current_project}
        Path: #{active_project_path}
        Rails version: #{rails_version}
        API only: #{is_api_only ? "Yes" : "No"}
        
        Project structure:
        #{get_directory_structure(active_project_path, max_depth: 2)}
      INFO
    end

    private

    # Utility functions for Rails operations
    def get_directory_structure(path, max_depth: 3, current_depth: 0, prefix: "")
      return "" if current_depth > max_depth || !File.directory?(path)

      # Define ignored directories
      ignored_dirs = [
        ".git", "node_modules", "tmp", "log",
        "storage", "coverage", "public/assets",
        "public/packs", ".bundle", "vendor/bundle",
        "vendor/cache", ".ruby-lsp"
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
  end
end
