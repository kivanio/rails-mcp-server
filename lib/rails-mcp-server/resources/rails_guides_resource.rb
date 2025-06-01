module RailsMcpServer
  class RailsGuidesResource < BaseGuideResource
    uri "rails://guides/{guide_name}"

    # Resource metadata
    resource_name "Rails Guides"
    description "Access to specific Rails documentation"
    mime_type "text/markdown"

    protected

    def framework_name
      "Rails"
    end

    def resource_directory
      "rails"
    end

    def download_command
      "rails-mcp-server-download-resources rails"
    end

    # Rails guides don't use handbook/reference sections
    def supports_sections?
      false
    end
  end
end
