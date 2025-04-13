module RailsMcpServer
  class GetFile < BaseTool
    tool_name "get_file"

    description "Retrieve the complete content of a specific file with syntax highlighting. Use this to examine implementation details, configurations, or any text file in the project."

    arguments do
      required(:path).filled(:string).description("File path relative to the project root (e.g., 'app/models/user.rb', 'config/routes.rb'). Use list_files first if you're not sure about the exact path.")
    end

    def call(path:)
      unless current_project
        message = "No active project. Please switch to a project first."
        log(:warn, message)

        return message
      end

      full_path = File.join(active_project_path, path)

      unless File.exist?(full_path)
        message = "File '#{path}' not found in the project."
        log(:warn, message)

        return message
      end

      content = File.read(full_path)
      log(:debug, "Read file: #{path} (#{content.size} bytes)")

      "File: #{path}\n\n```#{get_file_extension(path)}\n#{content}\n```"
    end

    private

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
  end
end
