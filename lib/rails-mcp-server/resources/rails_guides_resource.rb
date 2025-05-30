module RailsMcpServer
  class RailsGuidesResource < BaseResource
    uri "rails://guides/{guide_name}"

    # Resource metadata
    resource_name "Rails Guides"
    description "Access to specific Rails documentation"
    mime_type "text/markdown"

    def content
      guide_name = params[:guide_name]
      manifest_file = File.join(config_dir, "resources", "rails", "manifest.yaml")

      unless File.exist?(manifest_file)
        log(:error, "No Rails guides found. Run 'rails-mcp-server-download-resources rails' first.")
        "No Rails guides found. Run 'rails-mcp-server-download-resources rails' first."
      end

      if !guide_name.nil? && !guide_name.strip.empty?
        log(:debug, "Loading Rails guide: #{guide_name}")
        load_guide(guide_name, manifest_file)
      else
        log(:debug, "Provide a name for a Rails guide")
        "Provide a name for a Rails guide"
      end
    end

    private

    def load_guide(guide_name, manifest_file)
      manifest = YAML.load_file(manifest_file)

      guide = manifest["files"].find do |filename, file_data|
        filename == "#{guide_name.gsub(/[^a-zA-Z0-9_-]/, "")}.md"
      end

      guides_path = File.dirname(manifest_file)
      if guide && File.exist?("#{guides_path}/#{guide[0]}")
        log(:debug, "Loading guide: #{guide[0]}")
        File.read("#{guides_path}/#{guide[0]}")
      else
        log(:error, "Guide not found: #{guide_name}")
        "Guide not found: #{guide_name}"
      end
    end
  end
end
