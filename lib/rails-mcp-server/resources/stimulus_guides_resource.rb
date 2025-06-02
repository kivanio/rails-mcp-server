module RailsMcpServer
  class StimulusGuidesResource < BaseResource
    include GuideLoaderTemplate

    uri "stimulus://guides/{guide_name}"
    resource_name "Stimulus Guides"
    description "Access to specific Stimulus documentation"
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

    # Stimulus guides use handbook/reference sections
    def supports_sections?
      true
    end
  end
end
