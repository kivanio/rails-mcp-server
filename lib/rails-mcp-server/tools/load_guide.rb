module RailsMcpServer
  class LoadGuide < BaseTool
    tool_name "load_guide"

    description "Load documentation guides from Rails, Turbo, Stimulus, or Custom. Use this to get guide content for context in conversations."

    arguments do
      required(:guides).filled(:string).description("The guides library to search: 'rails', 'turbo', 'stimulus', or 'custom'")
      optional(:guide).maybe(:string).description("Specific guide name to load. If not provided, returns available guides list.")
    end

    def call(guides:, guide: nil)
      # Normalize guides parameter
      guides_type = guides.downcase.strip

      # Validate supported guide types
      unless %w[rails turbo stimulus custom].include?(guides_type)
        message = "Unsupported guide type '#{guides_type}'. Supported types: rails, turbo, stimulus, custom."
        log(:error, message)
        return message
      end

      if guide.nil? || guide.strip.empty?
        log(:debug, "Loading available #{guides_type} guides...")
        load_guides_list(guides_type)
      else
        log(:debug, "Loading specific #{guides_type} guide: #{guide}")
        load_specific_guide(guide, guides_type)
      end
    end

    private

    def load_guides_list(guides_type)
      case guides_type
      when "rails"
        uri = "rails://guides"
        read_resource(uri, RailsGuidesResources)
      when "stimulus"
        uri = "stimulus://guides"
        read_resource(uri, StimulusGuidesResources)
      when "turbo"
        uri = "turbo://guides"
        read_resource(uri, TurboGuidesResources)
      when "custom"
        uri = "custom://guides"
        read_resource(uri, CustomGuidesResources)
      else
        "Guide type '#{guides_type}' not supported."
      end
    end

    def load_specific_guide(guide_name, guides_type)
      # First try exact match
      exact_match_content = try_exact_match(guide_name, guides_type)
      return exact_match_content if exact_match_content && !exact_match_content.include?("Guide not found")

      # If exact match fails, try fuzzy matching
      try_fuzzy_matching(guide_name, guides_type)
    end

    def try_exact_match(guide_name, guides_type)
      case guides_type
      when "rails"
        uri = "rails://guides/#{guide_name}"
        read_resource(uri, RailsGuidesResource, {guide_name: guide_name})
      when "stimulus"
        uri = "stimulus://guides/#{guide_name}"
        read_resource(uri, StimulusGuidesResource, {guide_name: guide_name})
      when "turbo"
        uri = "turbo://guides/#{guide_name}"
        read_resource(uri, TurboGuidesResource, {guide_name: guide_name})
      when "custom"
        uri = "custom://guides/#{guide_name}"
        read_resource(uri, CustomGuidesResource, {guide_name: guide_name})
      else
        "Guide type '#{guides_type}' not supported."
      end
    end

    def try_fuzzy_matching(guide_name, guides_type)
      # Get all matching guides using the base guide resource directly
      matching_guides = find_matching_guides(guide_name, guides_type)

      case matching_guides.size
      when 0
        format_guide_not_found_message(guide_name, guides_type)
      when 1
        # Load the single match
        match = matching_guides.first
        log(:debug, "Found single fuzzy match: #{match}")
        try_exact_match(match, guides_type)
      when 2..3
        # Load multiple matches (up to 3)
        log(:debug, "Found #{matching_guides.size} fuzzy matches, loading all")
        load_multiple_guides(matching_guides, guides_type, guide_name)
      else
        # Too many matches, show options
        format_multiple_matches_message(guide_name, matching_guides, guides_type)
      end
    end

    def find_matching_guides(guide_name, guides_type)
      # Get the manifest to find matching files
      manifest = load_manifest_for_guides_type(guides_type)
      return [] unless manifest

      available_guides = manifest["files"].keys.select { |f| f.end_with?(".md") }.map { |f| f.sub(".md", "") } # rubocop:disable Performance/ChainArrayAllocation

      # Generate variations and find matches
      variations = generate_guide_name_variations(guide_name, guides_type)
      matching_guides = []

      variations.each do |variation|
        matches = available_guides.select do |guide|
          guide.downcase.include?(variation.downcase) ||
            variation.downcase.include?(guide.downcase) ||
            guide.gsub(/[_\-\s]/, "").downcase.include?(variation.gsub(/[_\-\s]/, "").downcase)
        end
        matching_guides.concat(matches)
      end

      matching_guides.uniq.sort # rubocop:disable Performance/ChainArrayAllocation
    end

    def load_manifest_for_guides_type(guides_type)
      config = RailsMcpServer.config
      manifest_file = File.join(config.config_dir, "resources", guides_type, "manifest.yaml")

      return nil unless File.exist?(manifest_file)

      YAML.load_file(manifest_file)
    rescue => e
      log(:error, "Failed to load manifest for #{guides_type}: #{e.message}")
      nil
    end

    def load_multiple_guides(guide_names, guides_type, original_query)
      results = []

      results << "# Multiple Guides Found for '#{original_query}'"
      results << ""
      results << "Found #{guide_names.size} matching guides. Loading all:\n"

      guide_names.each_with_index do |guide_name, index|
        results << "---"
        results << ""
        results << "## #{index + 1}. #{guide_name}"
        results << ""

        content = try_exact_match(guide_name, guides_type)
        if content && !content.include?("Guide not found") && !content.include?("Error")
          # Remove the header from individual guide content to avoid duplication
          clean_content = content.sub(/^#[^\n]*\n/, "").sub(/^\*\*Source:.*?\n---\n/m, "")
          results << clean_content.strip
        else
          results << "*Failed to load this guide*"
        end

        results << "" if index < guide_names.size - 1
      end

      results.join("\n")
    end

    def format_multiple_matches_message(guide_name, matches, guides_type)
      message = <<~MSG
        # Multiple Guides Found

        Found #{matches.size} guides matching '#{guide_name}' in #{guides_type} guides:

      MSG

      matches.first(10).each_with_index do |match, index|
        message += "#{index + 1}. #{match}\n"
      end

      if matches.size > 10
        message += "... and #{matches.size - 10} more\n"
      end

      message += <<~MSG

        ## To load a specific guide, use the exact name:
        ```
      MSG

      matches.first(3).each do |match|
        message += "load_guide guides: \"#{guides_type}\", guide: \"#{match}\"\n"
      end

      message += "```\n"
      message
    end

    def read_resource(uri, resource_class, params = {})
      # Check if the resource supports the instance method (from templating extension)
      if resource_class.respond_to?(:instance)
        instance = resource_class.instance(uri)
        return instance.content
      end

      # Fallback: manually create instance with proper initialization
      create_resource_instance(resource_class, params)
    rescue => e
      log(:error, "Error reading resource #{uri}: #{e.message}")
      format_error_message("Error loading guide: #{e.message}")
    end

    def create_resource_instance(resource_class, params)
      # Create instance using the proper pattern for FastMcp resources
      instance = resource_class.allocate

      # Set up the instance with parameters
      instance.instance_variable_set(:@params, params)

      # Initialize the instance (this calls the BaseResource initialize)
      instance.send(:initialize)

      # Call content to get the actual guide content
      instance.content
    end

    def generate_guide_name_variations(guide_name, guides_type)
      variations = []

      # Original name
      variations << guide_name

      # Underscore variations
      variations << guide_name.gsub(/[_-]/, "_")
      variations << guide_name.gsub(/\s+/, "_")

      # Hyphen variations
      variations << guide_name.gsub(/[_-]/, "-")
      variations << guide_name.gsub(/\s+/, "-")

      # Case variations
      variations << guide_name.downcase
      variations << guide_name.upcase

      # Remove special characters
      variations << guide_name.gsub(/[^a-zA-Z0-9_\/.-]/, "")

      # Common guide patterns (snake_case, kebab-case)
      if !guide_name.include?("_")
        variations << guide_name.gsub(/([a-z])([A-Z])/, '\1_\2').downcase
      end

      # For Stimulus/Turbo, try with handbook/ and reference/ prefixes
      # Custom guides use flat structure like Rails, so no prefixes needed
      unless guide_name.include?("/") || guides_type == "custom" || guides_type == "rails"
        variations << "handbook/#{guide_name}"
        variations << "reference/#{guide_name}"
      end

      # Remove path prefixes for alternatives (for Stimulus/Turbo)
      if guide_name.include?("/") && guides_type != "custom" && guides_type != "rails"
        base_name = guide_name.split("/").last
        variations << base_name
        variations.concat(generate_guide_name_variations(base_name, guides_type))
      end

      variations.uniq.compact # rubocop:disable Performance/ChainArrayAllocation
    end

    def format_guide_not_found_message(guide_name, guides_type)
      message = <<~MSG
        # Guide Not Found
        
        Guide '#{guide_name}' not found in #{guides_type} guides.
        
        ## Suggestions:
        - Use `load_guide guides: "#{guides_type}"` to see all available guides
        - Check the guide name spelling
        - Try common variations like:
          - `#{guide_name.gsub(/[_-]/, "_")}`
          - `#{guide_name.gsub(/\s+/, "_")}`
          - `#{guide_name.downcase}`
      MSG

      # Add framework-specific suggestions
      case guides_type
      when "stimulus", "turbo"
        message += <<~MSG
          - Try with section prefix: `handbook/#{guide_name}` or `reference/#{guide_name}`
          - Try without section prefix if you used one
        MSG
      when "custom"
        message += <<~MSG
          - Import custom guides with: `rails-mcp-server-download-resources --file /path/to/guides`
          - Make sure your custom guides have been imported
        MSG
      end

      message += <<~MSG
        
        ## Available Commands:
        - List guides: `load_guide guides: "#{guides_type}"`
        - Load guide: `load_guide guides: "#{guides_type}", guide: "guide_name"`
        
        ## Example Usage:
        ```
      MSG

      case guides_type
      when "rails"
        message += <<~MSG
          load_guide guides: "rails", guide: "active_record_validations"
          load_guide guides: "rails", guide: "getting_started"
        MSG
      when "stimulus"
        message += <<~MSG
          load_guide guides: "stimulus", guide: "actions"
          load_guide guides: "stimulus", guide: "01_introduction"
          load_guide guides: "stimulus", guide: "handbook/02_hello_stimulus"
        MSG
      when "turbo"
        message += <<~MSG
          load_guide guides: "turbo", guide: "drive"
          load_guide guides: "turbo", guide: "02_drive"
          load_guide guides: "turbo", guide: "reference/attributes"
        MSG
      when "custom"
        message += <<~MSG
          load_guide guides: "custom", guide: "api_documentation"
          load_guide guides: "custom", guide: "setup_guide"
          load_guide guides: "custom", guide: "user_manual"
        MSG
      end

      message += "```\n"

      log(:warn, "Guide not found: #{guide_name}")
      message
    end

    def format_error_message(message)
      <<~MSG
        # Error Loading Guide
        
        #{message}
        
        ## Troubleshooting:
        - Ensure guides are downloaded: `rails-mcp-server-download-resources [rails|stimulus|turbo]`
        - For custom guides: `rails-mcp-server-download-resources --file /path/to/guides`
        - Check that the MCP server is properly configured
        - Verify guide name is correct
        - Use `load_guide guides: "[rails|stimulus|turbo|custom]"` to see available guides
      MSG
    end
  end
end
