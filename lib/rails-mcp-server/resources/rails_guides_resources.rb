module RailsMcpServer
  class RailsGuidesResources < BaseResource
    uri "rails://guides"

    # Resource metadata
    resource_name "Rails Guides"
    description "Access to available Rails guides"
    mime_type "text/markdown"

    def content
      manifest_file = File.join(config_dir, "resources", "rails", "manifest.yaml")

      unless File.exist?(manifest_file)
        log(:error, "No Rails guides found. Run 'rails-mcp-server-download-resources rails' first.")
        "No Rails guides found. Run 'rails-mcp-server-download-resources rails' first."
      end

      log(:debug, "Loading Rails guides...")
      load_guides_index(manifest_file)
    end

    private

    def load_guides_index(manifest_file)
      manifest = YAML.load_file(manifest_file)
      guides = []

      manifest["files"].each do |filename, file_data|
        log(:debug, "Loading guide: #{filename}")

        file_uri = filename.sub(".md", "")
        guide_info = <<~GUIDE
          uri: "#{uri}/#{file_uri}",
          #{file_data["title"]}
          #{file_data["description"]}
        GUIDE

        guides << guide_info
      end

      guides.join("\n---\n")
    end
  end
end
