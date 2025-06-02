module RailsMcpServer
  class RailsGuidesResources < BaseResource
    include GuideLoaderTemplate

    uri "rails://guides"
    resource_name "Rails Guides List"
    description "Access to available Rails guides"
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

    def example_guides
      [
        {guide: "active_record_validations", comment: "Load validations guide"},
        {guide: "getting_started", comment: "Load getting started guide"},
        {guide: "routing", comment: "Load routing guide"}
      ]
    end

    # Rails guides don't use handbook/reference sections
    def supports_sections?
      false
    end
  end
end
