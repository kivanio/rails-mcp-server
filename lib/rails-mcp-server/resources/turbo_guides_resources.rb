module RailsMcpServer
  class TurboGuidesResources < BaseGuideResourcesList
    uri "turbo://guides"

    # Resource metadata
    resource_name "Turbo Guides"
    description "Access to available Turbo guides"
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

    def example_guides
      [
        {guide: "drive", comment: "Load drive reference"},
        {guide: "02_drive", comment: "Load drive handbook"},
        {guide: "reference/frames", comment: "Load frames with full path"}
      ]
    end

    # Turbo guides use handbook/reference sections
    def supports_sections?
      true
    end
  end
end
