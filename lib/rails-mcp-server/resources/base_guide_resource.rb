module RailsMcpServer
  # Base class for all guide resources (Rails, Stimulus, Turbo)
  # Provides common functionality for loading and formatting documentation guides
  class BaseGuideResource < BaseResource
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

    # Common content loading logic
    def content
      guide_name = params[:guide_name]
      manifest_file = File.join(config_dir, "resources", resource_directory, "manifest.yaml")

      unless File.exist?(manifest_file)
        log(:error, "No #{framework_name} guides found. Run '#{download_command}' first.")
        return "No #{framework_name} guides found. Run '#{download_command}' first."
      end

      if !guide_name.nil? && !guide_name.strip.empty?
        log(:debug, "Loading #{framework_name} guide: #{guide_name}")
        load_guide(guide_name, manifest_file)
      else
        log(:debug, "Provide a name for a #{framework_name} guide")
        "Provide a name for a #{framework_name} guide"
      end
    end

    protected

    # Load a specific guide with fuzzy matching support
    def load_guide(guide_name, manifest_file)
      manifest = YAML.load_file(manifest_file)
      normalized_guide_name = guide_name.gsub(/[^a-zA-Z0-9_\/.-]/, "")

      # Find the guide file
      filename, guide_data = find_guide_file(normalized_guide_name, manifest)

      if filename && guide_data
        guides_path = File.dirname(manifest_file)
        guide_file_path = File.join(guides_path, filename)

        if File.exist?(guide_file_path)
          log(:debug, "Loading guide: #{filename}")
          content = File.read(guide_file_path)
          format_guide_content(content, guide_name, guide_data, filename)
        else
          format_not_found_message(guide_name, manifest)
        end
      else
        format_not_found_message(guide_name, manifest)
      end
    end

    # Find guide file with exact and fuzzy matching
    def find_guide_file(normalized_guide_name, manifest)
      # Try exact matches first
      possible_filenames = generate_possible_filenames(normalized_guide_name)

      possible_filenames.each do |possible_filename|
        if manifest["files"][possible_filename]
          return [possible_filename, manifest["files"][possible_filename]]
        end
      end

      # If not found, try fuzzy matching
      matching_files = fuzzy_match_files(normalized_guide_name, manifest)

      case matching_files.size
      when 1
        matching_files.first
      when 0
        [nil, nil]
      else
        matches = matching_files.map(&:first).map { |f| f.sub(".md", "") }.join(", ") # rubocop:disable Performance/ChainArrayAllocation
        raise StandardError, "Multiple guides found matching '#{normalized_guide_name}': #{matches}. Please be more specific."
      end
    end

    # Generate possible filename variations for exact matching
    def generate_possible_filenames(normalized_guide_name)
      if supports_sections?
        [
          "#{normalized_guide_name}.md",
          "handbook/#{normalized_guide_name}.md",
          "reference/#{normalized_guide_name}.md"
        ]
      else
        ["#{normalized_guide_name}.md"]
      end
    end

    # Perform fuzzy matching on guide files
    def fuzzy_match_files(normalized_guide_name, manifest)
      manifest["files"].select do |file, _|
        next false unless file.end_with?(".md")

        file_name_base = file.sub(".md", "").split("/").last
        search_term = normalized_guide_name.split("/").last

        file_name_base.include?(search_term) ||
          search_term.include?(file_name_base) ||
          file_name_base.gsub(/[_-]/, "").downcase.include?(search_term.gsub(/[_-]/, "").downcase) ||
          search_term.gsub(/[_-]/, "").downcase.include?(file_name_base.gsub(/[_-]/, "").downcase)
      end.to_a
    end

    # Format the guide content with appropriate headers
    def format_guide_content(content, guide_name, guide_data, filename)
      title = guide_data["title"] || guide_name.gsub(/[_-]/, " ").split.map(&:capitalize).join(" ")

      if supports_sections?
        section = determine_section(filename)
        header = <<~HEADER
          # #{title}
          
          **Source:** #{framework_name} #{section}
          **Guide:** #{guide_name}
          **File:** #{filename}
          
          ---
          
        HEADER
      else
        header = <<~HEADER
          # #{title}
          
          **Source:** #{framework_name} Guides
          **Guide:** #{guide_name}
          
          ---
          
        HEADER
      end

      header + content
    end

    # Determine section from filename (handbook/reference)
    def determine_section(filename)
      return "Handbook" if filename.start_with?("handbook/")
      return "Reference" if filename.start_with?("reference/")
      "Documentation"
    end

    # Format guide not found message with framework-specific suggestions
    def format_not_found_message(guide_name, manifest)
      available_guides = manifest["files"].keys.select { |f| f.end_with?(".md") }.map { |f| f.sub(".md", "") } # rubocop:disable Performance/ChainArrayAllocation
      normalized_guide_name = guide_name.gsub(/[^a-zA-Z0-9_\/.-]/, "").downcase

      suggestions = find_suggestions(normalized_guide_name, available_guides)

      message = "# Guide Not Found\n\n"
      message += "Guide '#{guide_name}' not found in #{framework_name} guides.\n\n"

      if suggestions.any?
        message += "## Did you mean one of these?\n\n"
        suggestions.each { |suggestion| message += "- #{suggestion}\n" }
        message += "\n**Try:** `load_guide guides: \"#{framework_name.downcase}\", guide: \"#{suggestions.first}\"`\n"
      else
        message += format_available_guides_section(available_guides)
        message += "Use `load_guide guides: \"#{framework_name.downcase}\"` to see all available guides with descriptions.\n"
      end

      log(:error, "Guide not found: #{guide_name}")
      message
    end

    # Find suggestions based on partial matching
    def find_suggestions(normalized_guide_name, available_guides)
      available_guides.select do |guide|
        guide_base = guide.split("/").last.downcase
        search_base = normalized_guide_name.split("/").last.downcase

        guide_base.include?(search_base) ||
          search_base.include?(guide_base) ||
          guide_base.gsub(/[_-]/, "").include?(search_base.gsub(/[_-]/, ""))
      end
    end

    # Format available guides section
    def format_available_guides_section(available_guides)
      return "\n" unless supports_sections?

      handbook_guides = available_guides.select { |g| g.start_with?("handbook/") }
      reference_guides = available_guides.select { |g| g.start_with?("reference/") }

      message = "## Available #{framework_name} Guides:\n\n"

      if handbook_guides.any?
        message += "### Handbook:\n"
        handbook_guides.each { |guide| message += "- #{guide.sub("handbook/", "")}\n" }
        message += "\n"
      end

      if reference_guides.any?
        message += "### Reference:\n"
        reference_guides.each { |guide| message += "- #{guide.sub("reference/", "")}\n" }
        message += "\n"
      end

      message
    end

    # Override in subclasses if they support handbook/reference sections
    def supports_sections?
      false
    end

    # Format error messages consistently
    def format_error_message(message)
      "# Error\n\n#{message}"
    end
  end
end
