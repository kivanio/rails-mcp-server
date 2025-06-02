module RailsMcpServer
  class CustomGuidesResources < BaseGuideResourcesList
    uri "custom://guides"

    # Resource metadata
    resource_name "Custom Guides"
    description "Access to available custom imported guides"
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

    def example_guides
      [
        {guide: "api_documentation", comment: "Load API documentation"},
        {guide: "setup_guide", comment: "Load setup instructions"},
        {guide: "user_manual", comment: "Load user manual"}
      ]
    end

    # Custom guides don't use handbook/reference sections (flat structure like Rails)
    def supports_sections?
      false
    end
  end
end
