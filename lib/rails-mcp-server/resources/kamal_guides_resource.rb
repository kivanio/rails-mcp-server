module RailsMcpServer
  class KamalGuidesResource < BaseResource
    include GuideLoaderTemplate

    uri "kamal://guides/{guide_name}"
    resource_name "Kamal Guides"
    description "Access to specific Kamal deployment documentation"
    mime_type "text/markdown"

    protected

    def framework_name
      "Kamal"
    end

    def resource_directory
      "kamal"
    end

    def download_command
      "rails-mcp-server-download-resources kamal"
    end

    # Kamal guides have subdirectories but not handbook/reference sections
    def supports_sections?
      false
    end

    # Override for Kamal's directory structure
    def framework_specific_filenames(normalized_guide_name)
      possible_files = []

      if normalized_guide_name.include?("/")
        possible_files << normalized_guide_name
        possible_files << "#{normalized_guide_name}.md"
      else
        %w[installation configuration commands hooks upgrading].each do |section|
          possible_files << "#{section}/#{normalized_guide_name}.md"
          possible_files << "#{section}/index.md" if normalized_guide_name == section
        end
        possible_files << "#{normalized_guide_name}/index.md"
      end

      possible_files
    end

    # Override for Kamal's section detection
    def framework_specific_section(filename)
      case filename
      when /^installation\// then "Installation"
      when /^configuration\// then "Configuration"
      when /^commands\// then "Commands"
      when /^hooks\// then "Hooks"
      when /^upgrading\// then "Upgrading"
      else; "Documentation"
      end
    end

    # Enhanced fuzzy matching for hierarchical structure
    def fuzzy_match_files(normalized_guide_name, manifest)
      search_term = normalized_guide_name.downcase

      manifest["files"].select do |file, _|
        next false unless file.end_with?(".md")

        file_path = file.downcase
        file_name_base = file.sub(".md", "").split("/").last.downcase
        file_full_path = file.sub(".md", "").downcase

        file_path.include?(search_term) ||
          file_name_base.include?(search_term) ||
          search_term.include?(file_name_base) ||
          file_full_path.include?(search_term) ||
          search_term.include?(file_full_path) ||
          file_name_base.gsub(/[_-]/, "").include?(search_term.gsub(/[_-]/, "")) ||
          search_term.gsub(/[_-]/, "").include?(file_name_base.gsub(/[_-]/, ""))
      end.to_a
    end
  end
end
