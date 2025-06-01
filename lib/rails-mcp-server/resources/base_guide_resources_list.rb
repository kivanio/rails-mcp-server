module RailsMcpServer
  # Base class for guide list resources (Rails, Stimulus, Turbo)
  # Provides common functionality for listing available documentation guides
  class BaseGuideResourcesList < BaseResource
    # Abstract methods that must be implemented by subclasses
    def framework_name
      raise NotImplementedError, "Subclasses must implement #framework_name"
    end

    def resource_directory
      raise NotImplementedError, "Subclasses must implement #resource_directory"
    end

    def download_command
      raise NotImplementedError, "Subclasses must implement #download_command"
    end

    def example_guides
      raise NotImplementedError, "Subclasses must implement #example_guides"
    end

    # Common content loading logic
    def content
      manifest_file = File.join(config_dir, "resources", resource_directory, "manifest.yaml")

      unless File.exist?(manifest_file)
        log(:error, "No #{framework_name} guides found. Run '#{download_command}' first.")
        return "No #{framework_name} guides found. Run '#{download_command}' first."
      end

      log(:debug, "Loading #{framework_name} guides...")
      load_guides_index(manifest_file)
    end

    protected

    # Load and format the guides index
    def load_guides_index(manifest_file)
      manifest = YAML.load_file(manifest_file)
      guides = []

      guides << "# Available #{framework_name} Guides\n"
      guides << "Use the `load_guide` tool with `guides: \"#{framework_name.downcase}\"` and `guide: \"guide_name\"` to load a specific guide.\n"

      if supports_sections?
        guides << "You can use either the full path (e.g., `handbook/01_introduction`) or just the filename (e.g., `01_introduction`).\n"
      end

      if supports_sections?
        guides.concat(format_sectioned_guides(manifest))
      else
        guides.concat(format_flat_guides(manifest))
      end

      guides << format_usage_examples

      guides.join("\n")
    end

    # Format guides organized by sections (handbook/reference)
    def format_sectioned_guides(manifest)
      handbook_guides = {}
      reference_guides = {}

      manifest["files"].each do |filename, file_data|
        next unless filename.end_with?(".md")

        log(:debug, "Processing guide: #{filename}")

        guide_name = filename.sub(".md", "")
        title = file_data["title"] || guide_name.split("/").last.gsub(/[_-]/, " ").split.map(&:capitalize).join(" ")
        description = file_data["description"] || ""

        if filename.start_with?("handbook/")
          handbook_guides[guide_name] = {title: title, description: description}
        elsif filename.start_with?("reference/")
          reference_guides[guide_name] = {title: title, description: description}
        end
      end

      guides = []

      # Add handbook section
      if handbook_guides.any?
        guides << "\n## Handbook (Main Documentation)\n"
        handbook_guides.each do |guide_name, data|
          short_name = guide_name.sub("handbook/", "")
          guides << format_guide_entry(data[:title], short_name, guide_name, data[:description])
        end
      end

      # Add reference section
      if reference_guides.any?
        guides << "\n## Reference (API Documentation)\n"
        reference_guides.each do |guide_name, data|
          short_name = guide_name.sub("reference/", "")
          guides << format_guide_entry(data[:title], short_name, guide_name, data[:description])
        end
      end

      guides
    end

    # Format guides in a flat structure (no sections)
    def format_flat_guides(manifest)
      guides = []

      manifest["files"].each do |filename, file_data|
        next unless filename.end_with?(".md")

        log(:debug, "Processing guide: #{filename}")

        guide_name = filename.sub(".md", "")
        title = file_data["title"] || guide_name.gsub(/[_-]/, " ").split.map(&:capitalize).join(" ")
        description = file_data["description"] || ""

        guides << format_guide_entry(title, guide_name, guide_name, description)
      end

      guides
    end

    # Format individual guide entry
    def format_guide_entry(title, short_name, full_name, description)
      if supports_sections? && short_name != full_name
        <<~GUIDE
          ### #{title}
          **Guide name:** `#{short_name}` or `#{full_name}`
          #{description.empty? ? "" : "**Description:** #{description}"}
        GUIDE
      else
        <<~GUIDE
          ## #{title}
          **Guide name:** `#{short_name}`
          #{description.empty? ? "" : "**Description:** #{description}"}
        GUIDE
      end
    end

    # Format usage examples section
    def format_usage_examples
      examples = example_guides

      usage = "\n## Example Usage:\n"
      usage += "```\n"

      examples.each do |example|
        usage += "load_guide guides: \"#{framework_name.downcase}\", guide: \"#{example[:guide]}\"#{example[:comment] ? " # " + example[:comment] : ""}\n"
      end

      usage += "```\n"
      usage
    end

    # Override in subclasses if they support handbook/reference sections
    def supports_sections?
      false
    end
  end
end
