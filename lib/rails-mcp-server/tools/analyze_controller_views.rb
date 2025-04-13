module RailsMcpServer
  class AnalyzeControllerViews < BaseTool
    tool_name "analyze_controller_views"

    description "Analyze the relationships between controllers, their actions, and corresponding views to understand the application's UI flow."

    arguments do
      optional(:controller_name).filled(:string).description("Name of a specific controller to analyze (e.g., 'UsersController' or 'users'). If omitted, all controllers will be analyzed.")
    end

    def call(controller_name: nil)
      unless current_project
        message = "No active project. Please switch to a project first."
        log(:warn, message)

        return message
      end

      # Find all controllers
      controllers_dir = File.join(active_project_path, "app", "controllers")
      unless File.directory?(controllers_dir)
        message = "Controllers directory not found at app/controllers."
        log(:warn, message)

        return message
      end

      # Get all controller files
      controller_files = Dir.glob(File.join(controllers_dir, "**", "*_controller.rb"))

      if controller_files.empty?
        message = "No controllers found in the project."
        log(:warn, message)

        return message
      end

      # If a specific controller was requested, filter the files
      if controller_name
        # Normalize controller name (allow both 'users' and 'UsersController')
        controller_name = "#{controller_name.sub(/_?controller$/i, "").downcase}_controller.rb"
        controller_files = controller_files.select { |f| File.basename(f).downcase == controller_name }

        if controller_files.empty?
          message = "Controller '#{controller_name}' not found."
          log(:warn, message)

          return message
        end
      end

      # Parse controllers to extract actions
      controllers_data = {}

      controller_files.each do |file_path|
        file_content = File.read(file_path)
        controller_class = File.basename(file_path, ".rb").gsub(/_controller$/i, "").then { |s| camelize(s) } + "Controller"

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
        routes_output = RailsMcpServer::RunProcess.execute_rails_command(
          active_project_path,
          "bin/rails routes -c #{controller_class}"
        )

        routes = {}
        if routes_output && !routes_output.empty?
          routes_output.split("\n").each do |line|
            next if line.include?("(erb):") || line.include?("Prefix") || line.strip.empty?
            parts = line.strip.split(/\s+/)
            if parts.size >= 4
              # Get action name from the rails routes output
              action = parts[1].to_s.strip.downcase
              if actions.include?(action)
                verb = parts[0].to_s.strip
                path = parts[2].to_s.strip
                routes[action] = {verb: verb, path: path}
              end
            end
          end
        end

        # Find views for each action
        views_dir = File.join(active_project_path, "app", "views", File.basename(file_path, "_controller.rb"))
        views = {}

        if File.directory?(views_dir)
          actions.each do |action|
            # Look for view templates with various extensions
            view_files = Dir.glob(File.join(views_dir, "#{action}.*"))
            if view_files.any?
              views[action] = {
                templates: view_files.map { |f| f.sub("#{active_project_path}/", "") },
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
          file: file_path.sub("#{active_project_path}/", ""),
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

    private

    def camelize(string)
      string.split("_").map(&:capitalize).join
    end
  end
end
