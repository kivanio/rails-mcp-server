module RailsMcpServer
  class CustomGuidesResource < BaseResource
    include GuideLoaderTemplate

    uri "custom://guides/{guide_name}"
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

    # Custom display name to show original filename
    def customize_display_name(guide_name, guide_data)
      guide_data["original_filename"] || guide_name
    end

    # Custom error message for imports
    def customize_not_found_message(message, guide_name)
      message + "\n**Note:** Make sure you've imported your custom guides with `#{download_command}`\n"
    end

    # Custom manifest error handling
    def handle_manifest_error(error)
      case error.message
      when /No Custom guides found/
        format_error_message(
          "No custom guides found. Import guides with:\n" \
          "`rails-mcp-server-download-resources --file /path/to/guide.md`\n" \
          "or\n" \
          "`rails-mcp-server-download-resources --file /path/to/guides/`"
        )
      else
        super
      end
    end
  end
end
