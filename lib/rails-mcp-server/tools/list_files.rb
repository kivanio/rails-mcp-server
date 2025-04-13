module RailsMcpServer
  class ListFiles < BaseTool
    tool_name "list_files"

    description "List files in the Rails project matching specific criteria. Use this to explore project directories or locate specific file types. If no parameters are provided, lists files in the project root."

    arguments do
      optional(:directory).filled(:string).description("Directory path relative to the project root (e.g., 'app/models', 'config'). Leave empty to list files at the root.")
      optional(:pattern).filled(:string).description("File pattern using glob syntax (e.g., '*.rb' for Ruby files, '*.erb' for ERB templates, '*_controller.rb' for controllers)")
    end

    def call(directory: "", pattern: "*.rb")
      unless current_project
        message = "No active project. Please switch to a project first."
        log(:warn, message)

        return message
      end

      full_path = File.join(active_project_path, directory)
      unless File.directory?(full_path)
        message = "Directory '#{directory}' not found in the project."
        log(:warn, message)

        return message
      end

      # Check if this is a git repository
      is_git_repo = system("cd #{active_project_path} && git rev-parse --is-inside-work-tree > /dev/null 2>&1")

      if is_git_repo
        log(:debug, "Project is a git repository, using git ls-files")

        # Use git ls-files for tracked files
        relative_dir = directory.empty? ? "" : "#{directory}/"
        git_cmd = "cd #{active_project_path} && git ls-files --cached --others --exclude-standard #{relative_dir}#{pattern}"

        files = `#{git_cmd}`.split("\n").map(&:strip).sort # rubocop:disable Performance/ChainArrayAllocation
      else
        log(:debug, "Project is not a git repository or git not available, using Dir.glob")

        # Use Dir.glob as fallback
        files = Dir.glob(File.join(full_path, pattern))
          .map { |f| f.sub("#{active_project_path}/", "") }
          .reject { |file| file.start_with?(".git/", ".ruby-lsp/", "node_modules/", "storage/", "public/assets/", "public/packs/", ".bundle/", "vendor/bundle/", "vendor/cache/", "tmp/", "log/") } # rubocop:disable Performance/ChainArrayAllocation
          .sort # rubocop:disable Performance/ChainArrayAllocation
      end

      log(:debug, "Found #{files.size} files matching pattern (respecting .gitignore and ignoring node_modules)")

      "Files in #{directory.empty? ? "project root" : directory} matching '#{pattern}':\n\n#{files.join("\n")}"
    end
  end
end
