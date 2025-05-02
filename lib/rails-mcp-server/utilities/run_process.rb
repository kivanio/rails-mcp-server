require "bundler"

module RailsMcpServer
  class RunProcess
    def self.execute_rails_command(project_path, command)
      subprocess_env = ENV.to_h.merge(Bundler.original_env).merge(
        "BUNDLE_GEMFILE" => File.join(project_path, "Gemfile")
      )

      RailsMcpServer.log(:debug, "Executing: #{command}")

      # Execute the command and capture stdout, stderr, and status
      stdout_str, stderr_str, status = Open3.capture3(subprocess_env, command, chdir: project_path)

      if status.success?
        RailsMcpServer.log(:debug, "Command succeeded")
        stdout_str
      else
        # Log error details
        RailsMcpServer.log(:error, "Command failed with status: #{status.exitstatus}")
        RailsMcpServer.log(:error, "stderr: #{stderr_str}")

        # Return error message
        "Error executing Rails command: #{command}\n\n#{stderr_str}"
      end
    rescue => e
      RailsMcpServer.log(:error, "Exception executing Rails command: #{e.message}")
      "Exception executing command: #{e.message}"
    end
  end
end
