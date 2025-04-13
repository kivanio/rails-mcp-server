module RailsMcpServer
  class SwitchProject < BaseTool
    tool_name "switch_project"

    description "Change the active Rails project to interact with a different codebase. Must be called before using other tools. Available projects are defined in the projects.yml configuration file."

    arguments do
      required(:project_name).filled(:string).description("Name of the project as defined in the projects.yml file (case-sensitive)")
    end

    def call(project_name:)
      if projects.key?(project_name)
        self.current_project = project_name
        self.active_project_path = File.expand_path(projects[project_name])
        log(:info, "Switched to project: #{project_name} at path: #{active_project_path}")

        "Switched to project: #{project_name} at path: #{active_project_path}"
      else
        log(:warn, "Project not found: #{project_name}")

        "Project '#{project_name}' not found. Available projects: #{projects.keys.join(", ")}"
      end
    end
  end
end
