module RailsMcpServer
  class StimulusGuidesResources < BaseGuideResourcesList
    uri "stimulus://guides"

    # Resource metadata
    resource_name "Stimulus Guides"
    description "Access to available Stimulus guides"
    mime_type "text/markdown"

    protected

    def framework_name
      "Stimulus"
    end

    def resource_directory
      "stimulus"
    end

    def download_command
      "rails-mcp-server-download-resources stimulus"
    end

    def example_guides
      [
        {guide: "actions", comment: "Load actions reference"},
        {guide: "01_introduction", comment: "Load introduction"},
        {guide: "reference/targets", comment: "Load targets with full path"}
      ]
    end

    # Stimulus guides use handbook/reference sections
    def supports_sections?
      true
    end
  end
end
