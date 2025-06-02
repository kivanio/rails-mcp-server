require "fileutils"
require "digest"
require "yaml"

module RailsMcpServer
  # Imports local markdown files into the Rails MCP Server resource system
  class ResourceImporter
    # Custom error for import-related issues
    class ImportError < StandardError; end

    # Results for import operations
    IMPORT_RESULTS = {
      imported: :imported,
      skipped: :skipped,
      failed: :failed
    }.freeze

    attr_reader :resource_name, :config_dir, :source_path, :resource_folder, :manifest_file

    # Initialize importer for local files
    #
    # @param resource_name [String] Name of the resource (usually "custom")
    # @param config_dir [String] Base configuration directory path
    # @param source_path [String] Path to source file or directory
    # @param force [Boolean] Force re-import of existing files
    # @param verbose [Boolean] Enable verbose output
    def initialize(resource_name, config_dir:, source_path:, force: false, verbose: false)
      @resource_name = resource_name.to_s
      @config_dir = config_dir
      @source_path = source_path
      @force = force
      @verbose = verbose

      validate_source_path
      setup_paths
    end

    # Import all markdown files from the source
    #
    # @return [Hash] Summary of import results
    def import
      setup_directories
      load_manifest

      log "Importing custom files from #{@source_path}..."

      results = {imported: 0, skipped: 0, failed: 0}
      files_to_import = collect_markdown_files

      if files_to_import.empty?
        log "No markdown files found in #{@source_path}"
        save_manifest
        return results
      end

      files_to_import.each do |file_path|
        result = import_file(file_path)
        results[result] += 1
      end

      save_manifest
      results
    end

    private

    # Validate that source path exists and is accessible
    def validate_source_path
      unless File.exist?(@source_path)
        raise ImportError, "Source path not found: #{@source_path}"
      end

      unless File.readable?(@source_path)
        raise ImportError, "Source path not readable: #{@source_path}"
      end
    end

    # Setup file system paths
    def setup_paths
      @resource_folder = File.join(@config_dir, "resources", @resource_name)
      @manifest_file = File.join(@resource_folder, "manifest.yaml")
    end

    # Create necessary directories
    def setup_directories
      FileUtils.mkdir_p(@resource_folder)
    end

    # Load existing manifest or create new one
    def load_manifest
      @manifest = if File.exist?(@manifest_file)
        YAML.load_file(@manifest_file)
      else
        create_default_manifest
      end
    end

    # Create default manifest for imported resources
    #
    # @return [Hash] Default manifest structure
    def create_default_manifest
      {
        "resource" => @resource_name,
        "base_url" => "local",
        "description" => "Custom imported documentation",
        "files" => {},
        "created_at" => Time.now.to_s,
        "updated_at" => Time.now.to_s
      }
    end

    # Save manifest to disk
    def save_manifest
      @manifest["updated_at"] = Time.now.to_s
      File.write(@manifest_file, @manifest.to_yaml)
    end

    # Collect markdown files from source path
    #
    # @return [Array<String>] List of markdown file paths
    def collect_markdown_files
      files = []

      if File.file?(@source_path)
        files << @source_path if markdown_file?(@source_path)
      elsif File.directory?(@source_path)
        # Only process direct children, not subdirectories
        Dir.glob(File.join(@source_path, "*.md")).each do |file_path|
          files << file_path if File.file?(file_path)
        end
      end

      files.sort
    end

    # Check if file is a markdown file
    #
    # @param file_path [String] Path to check
    # @return [Boolean] True if file has .md extension
    def markdown_file?(file_path)
      File.extname(file_path).casecmp(".md").zero?
    end

    # Import a single local file
    #
    # @param file_path [String] Path to the local file
    # @return [Symbol] Result of import operation
    def import_file(file_path)
      original_filename = File.basename(file_path)
      normalized_filename = normalize_filename(original_filename)
      destination_path = File.join(@resource_folder, normalized_filename)

      # Check if file exists and hasn't changed (using normalized filename as key)
      if File.exist?(destination_path) && !@force
        source_hash = calculate_file_hash(file_path)

        if @manifest["files"][normalized_filename] &&
            @manifest["files"][normalized_filename]["hash"] == source_hash
          log "Skipping #{original_filename} (unchanged)"
          return IMPORT_RESULTS[:skipped]
        end
      end

      log "Importing #{original_filename} -> #{normalized_filename}... ", newline: false

      begin
        content = File.read(file_path)
        save_imported_file(destination_path, content, normalized_filename, original_filename, file_path)
        log "done"
        IMPORT_RESULTS[:imported]
      rescue => e
        log "failed (#{e.message})"
        IMPORT_RESULTS[:failed]
      end
    end

    # Normalize filename to be filesystem-safe and search-friendly
    #
    # @param filename [String] Original filename
    # @return [String] Normalized filename
    def normalize_filename(filename)
      # Keep the .md extension
      basename = File.basename(filename, ".md")
      extension = File.extname(filename)

      # Normalize the basename:
      # 1. Convert to lowercase
      # 2. Replace spaces and non-alphanumeric chars with underscores
      # 3. Replace consecutive underscores with single underscore
      # 4. Remove leading/trailing underscores
      normalized = basename.downcase
        .gsub(/[^a-z0-9_\-.]/, "_")  # Replace non-alphanumeric chars with underscore
        .gsub(/_+/, "_")             # Replace multiple underscores with single
        .gsub(/^_+|_+$/, "")         # Remove leading/trailing underscores

      # Ensure we have a valid filename
      normalized = "untitled" if normalized.empty?

      "#{normalized}#{extension}"
    end

    # Save imported file and update manifest
    #
    # @param destination_path [String] Local destination path
    # @param content [String] File content
    # @param normalized_filename [String] Normalized filename (used as manifest key)
    # @param original_filename [String] Original filename
    # @param source_path [String] Original source file path
    def save_imported_file(destination_path, content, normalized_filename, original_filename, source_path)
      # Copy file to destination with normalized filename
      FileUtils.cp(source_path, destination_path)

      # Extract metadata for imported files using original filename for title extraction
      metadata = extract_metadata(content, original_filename)

      # Update manifest with normalized filename as key, original filename preserved
      @manifest["files"][normalized_filename] = {
        "original_filename" => original_filename,  # Preserve original name
        "hash" => calculate_file_hash(destination_path),
        "size" => File.size(destination_path),
        "imported_at" => Time.now.to_s
      }

      @manifest["files"][normalized_filename].merge!(metadata) if metadata
    end

    # Extract metadata from imported files
    #
    # @param content [String] File content
    # @param filename [String] Original filename for title extraction
    # @return [Hash] Extracted metadata
    def extract_metadata(content, filename)
      metadata = {}

      # Try to extract title from content first
      title = extract_title_from_content(content)

      # Fall back to humanized filename if no title found
      if title.nil? || title.strip.empty?
        base_name = File.basename(filename, ".md")
        title = humanize_filename(base_name)
      end

      metadata["title"] = title

      # Extract description from content
      description = extract_description_from_content(content)
      metadata["description"] = description unless description.empty?

      metadata
    end

    # Extract title from markdown content
    #
    # @param content [String] Markdown content
    # @return [String, nil] Extracted title or nil
    def extract_title_from_content(content)
      lines = content.lines

      # Look for H1 header (# Title)
      lines.each do |line|
        if line.strip =~ /^#\s+(.+)$/
          return $1.strip
        end
      end

      # Look for title with underline (Title\n===)
      lines.each_with_index do |line, index|
        next if index >= lines.length - 1

        if /^=+$/.match?(lines[index + 1].strip)
          return line.strip
        end
      end

      nil
    end

    # Extract description from content (first 200 chars)
    #
    # @param content [String] File content
    # @return [String] Extracted description
    def extract_description_from_content(content)
      # Remove title lines and YAML frontmatter
      clean_content = content.dup

      # Remove YAML frontmatter
      clean_content = clean_content.sub(/^---\s*\n.*?\n---\s*\n/m, "")

      # Remove H1 headers
      clean_content = clean_content.gsub(/^#\s+.*?\n/, "")

      # Remove title underlines
      clean_content = clean_content.gsub(/^.+\n=+\s*\n/, "")

      # Clean up content
      clean_content = clean_content.strip
      clean_content = clean_content.gsub(/\n+/, " ")      # Replace newlines with spaces
      clean_content = clean_content.gsub(/\s+/, " ")      # Normalize whitespace

      return "" if clean_content.empty?

      # Truncate to ~200 characters at word boundary
      if clean_content.length > 200
        truncate_at = clean_content.rindex(" ", 200) || 200
        description = clean_content[0...truncate_at] + "..."
      else
        description = clean_content
      end

      description
    end

    # Convert filename to human-readable title
    #
    # @param filename [String] Base filename without extension
    # @return [String] Humanized title
    def humanize_filename(filename)
      # Replace underscores and hyphens with spaces
      title = filename.gsub(/[_-]/, " ")

      # Remove leading numbers and dots (e.g., "01." or "1-")
      title = title.gsub(/^\d+[.\-_\s]*/, "")

      # Capitalize each word
      title = title.split(" ").map(&:capitalize).join(" ")

      # Handle common abbreviations
      title = title.gsub(/\bApi\b/, "API")
        .gsub(/\bHtml\b/, "HTML")
        .gsub(/\bCss\b/, "CSS")
        .gsub(/\bJs\b/, "JavaScript")
        .gsub(/\bUi\b/, "UI")
        .gsub(/\bUrl\b/, "URL")
        .gsub(/\bRest\b/, "REST")
        .gsub(/\bJson\b/, "JSON")
        .gsub(/\bXml\b/, "XML")
        .gsub(/\bSql\b/, "SQL")

      title.strip.empty? ? "Untitled Guide" : title
    end

    # Calculate SHA256 hash of file
    #
    # @param file_path [String] Path to file
    # @return [String] SHA256 hexdigest
    def calculate_file_hash(file_path)
      Digest::SHA256.file(file_path).hexdigest
    end

    # Log message if verbose mode is enabled
    #
    # @param message [String] Message to log
    # @param newline [Boolean] Whether to add newline
    def log(message, newline: true)
      return unless @verbose

      if newline
        puts message
      else
        print message
      end
    end
  end
end
