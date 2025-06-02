module RailsMcpServer
  class TurboGuidesResource < BaseResource
    include GuideLoaderTemplate

    uri "turbo://guides/{guide_name}"
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
