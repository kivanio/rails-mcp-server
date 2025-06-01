module RailsMcpServer
  class LoadGuide < BaseTool
    tool_name "load_guide"

    description "Load documentation guides from Rails, Turbo, or Stimulus. Use this to get guide content for context in conversations."

    arguments do
      required(:guides).filled(:string).description("The guides library to search: 'rails', 'turbo', or 'stimulus'")
      optional(:guide).maybe(:string).description("Specific guide name to load. If not provided, returns available guides list.")
    end

    def call(guides:, guide: nil)
      # Normalize guides parameter
      guides_type = guides.downcase.strip

      # Validate supported guide types
      unless %w[rails turbo stimulus].include?(guides_type)
        message = "Unsupported guide type '#{guides_type}'. Supported types: rails, turbo, stimulus."
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
      else
        "Guide type '#{guides_type}' not supported."
      end
    end

    def load_specific_guide(guide_name, guides_type)
      case guides_type
      when "rails"
        uri = "rails://guides/#{guide_name}"
        content = read_resource(uri, RailsGuidesResource, {guide_name: guide_name})
      when "stimulus"
        uri = "stimulus://guides/#{guide_name}"
        content = read_resource(uri, StimulusGuidesResource, {guide_name: guide_name})
      when "turbo"
        uri = "turbo://guides/#{guide_name}"
        content = read_resource(uri, TurboGuidesResource, {guide_name: guide_name})
      else
        return "Guide type '#{guides_type}' not supported."
      end

      # If the content indicates the guide wasn't found, try some common variations
      if content&.include?("Guide not found")
        # Try some common guide name variations
        variations = generate_guide_name_variations(guide_name)

        variations.each do |variation|
          next if variation == guide_name # Skip if same as original

          case guides_type
          when "rails"
            variant_uri = "rails://guides/#{variation}"
            variant_content = read_resource(variant_uri, RailsGuidesResource, {guide_name: variation})
          when "stimulus"
            variant_uri = "stimulus://guides/#{variation}"
            variant_content = read_resource(variant_uri, StimulusGuidesResource, {guide_name: variation})
          when "turbo"
            variant_uri = "turbo://guides/#{variation}"
            variant_content = read_resource(variant_uri, TurboGuidesResource, {guide_name: variation})
          end

          if variant_content && !variant_content.include?("Guide not found")
            log(:debug, "Found guide using variation: #{variation}")
            return variant_content
          end
        end

        # If still not found, return helpful message
        return format_guide_not_found_message(guide_name, guides_type)
      end

      content
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

    def generate_guide_name_variations(guide_name)
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
      unless guide_name.include?("/")
        variations << "handbook/#{guide_name}"
        variations << "reference/#{guide_name}"
      end

      # Remove path prefixes for alternatives
      if guide_name.include?("/")
        base_name = guide_name.split("/").last
        variations << base_name
        variations.concat(generate_guide_name_variations(base_name))
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
        - Check that the MCP server is properly configured
        - Verify guide name is correct
        - Use `load_guide guides: "[rails|stimulus|turbo]"` to see available guides
      MSG
    end
  end
end
