module RailsMcpServer
  class TurboGuidesResource < BaseGuideResource
    uri "turbo://guides/{guide_name}"

    # Resource metadata
    resource_name "Turbo Guides"
    description "Access to specific Turbo documentation"
    mime_type "text/markdown"

    protected

    def framework_name
      "Turbo"
    end

    def resource_directory
      "turbo"
    end

    def download_command
      "rails-mcp-server-download-resources turbo"
    end

    # Turbo guides use handbook/reference sections
    def supports_sections?
      true
    end
  end
end
