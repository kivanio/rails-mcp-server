module RailsMcpServer
  # Module for finding and matching guide files
  module GuideFileFinder
    protected

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
      possible_files = ["#{normalized_guide_name}.md"]

      # Add section prefixes for frameworks that support them
      if supports_sections?
        possible_files += [
          "handbook/#{normalized_guide_name}.md",
          "reference/#{normalized_guide_name}.md"
        ]
      end

      # Framework-specific filename generation can be overridden
      possible_files += framework_specific_filenames(normalized_guide_name) if respond_to?(:framework_specific_filenames, true)

      possible_files.uniq
    end

    # Perform fuzzy matching on guide files
    def fuzzy_match_files(normalized_guide_name, manifest)
      search_terms = generate_search_terms(normalized_guide_name)

      manifest["files"].select do |file, _|
        next false unless file.end_with?(".md")

        file_matches_any_search_term?(file, search_terms)
      end.to_a
    end

    # Generate search terms for fuzzy matching
    def generate_search_terms(normalized_guide_name)
      base_term = normalized_guide_name.split("/").last.downcase

      [
        base_term,
        base_term.gsub(/[_-]/, ""),
        base_term.gsub(/[_-]/, "_"),
        base_term.gsub(/[_-]/, "-")
      ].uniq
    end

    # Check if file matches any search term
    def file_matches_any_search_term?(file, search_terms)
      file_name_base = file.sub(".md", "").split("/").last.downcase
      file_name_normalized = file_name_base.gsub(/[_-]/, "")

      search_terms.any? do |term|
        term_normalized = term.gsub(/[_-]/, "")

        file_name_base.include?(term) ||
          term.include?(file_name_base) ||
          file_name_normalized.include?(term_normalized) ||
          term_normalized.include?(file_name_normalized)
      end
    end

    # Generate suggestions for similar guide names
    def find_suggestions(normalized_guide_name, available_guides)
      search_base = normalized_guide_name.split("/").last.downcase

      available_guides.select do |guide|
        guide_base = guide.split("/").last.downcase

        guide_base.include?(search_base) ||
          search_base.include?(guide_base) ||
          guide_base.gsub(/[_-]/, "").include?(search_base.gsub(/[_-]/, ""))
      end
    end
  end
end
