module RailsMcpServer
  class CustomGuidesResource < BaseGuideResource
    uri "custom://guides/{guide_name}"

    # Resource metadata
    resource_name "Custom Guides"
    description "Access to specific custom imported documentation"
    mime_type "text/markdown"

    protected

    def framework_name
      "Custom"
    end

    def resource_directory
      "custom"
    end

    def download_command
      "rails-mcp-server-download-resources --file /path/to/files"
    end

    # Custom guides don't use handbook/reference sections (flat structure like Rails)
    def supports_sections?
      false
    end
  end
end
