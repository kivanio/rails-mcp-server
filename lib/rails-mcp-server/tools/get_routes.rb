module RailsMcpServer
  class GetRoutes < BaseTool
    tool_name "get_routes"

    description "Retrieve all HTTP routes defined in the Rails application with their associated controllers and actions. Equivalent to running 'rails routes' command. This helps understand the API endpoints or page URLs available in the application."

    def call
      unless current_project
        message = "No active project. Please switch to a project first."
        log(:warn, message)

        return message
      end

      # Execute the Rails routes command
      routes_output = RailsMcpServer::RunProcess.execute_rails_command(
        active_project_path, "bin/rails routes"
      )
      log(:debug, "Routes command completed, output size: #{routes_output.size} bytes")

      "Rails Routes:\n\n```\n#{routes_output}\n```"
    end
  end
end
