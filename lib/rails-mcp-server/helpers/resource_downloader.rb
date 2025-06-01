require "net/http"
require "uri"
require "fileutils"
require "digest"
require "yaml"

module RailsMcpServer
  # Downloads and manages documentation resources for Rails MCP Server
  class ResourceDownloader
    # Custom error for download-related issues
    class DownloadError < StandardError; end

    # Results for download operations
    DOWNLOAD_RESULTS = {
      downloaded: :downloaded,
      skipped: :skipped,
      failed: :failed
    }.freeze

    attr_reader :resource_name, :config, :resource_folder, :manifest_file

    # Initialize downloader for a specific resource
    #
    # @param resource_name [String, Symbol] Name of the resource to download
    # @param config_dir [String] Base configuration directory path
    # @param force [Boolean] Force re-download of existing files
    # @param verbose [Boolean] Enable verbose output
    def initialize(resource_name, config_dir:, force: false, verbose: false)
      @resource_name = resource_name.to_s
      @config_dir = config_dir
      @force = force
      @verbose = verbose

      load_resource_config
      setup_paths
    end

    # Download all files for the configured resource
    #
    # @return [Hash] Summary of download results
    def download
      setup_directories
      load_manifest

      log "Downloading #{@resource_name} resources..."

      results = {downloaded: 0, skipped: 0, failed: 0}

      @config["files"].each do |file|
        result = download_file(file)
        results[result] += 1
      end

      save_manifest
      results
    end

    # Get list of available resources from configuration
    #
    # @param config_dir [String] Configuration directory path
    # @return [Array<String>] List of available resource names
    def self.available_resources(config_dir)
      config_file = File.join(File.dirname(__FILE__), "..", "..", "..", "config", "resources.yml")
      return [] unless File.exist?(config_file)

      YAML.load_file(config_file).keys
    rescue => e
      warn "Failed to load resource configuration: #{e.message}"
      []
    end

    private

    # Load resource configuration from YAML file
    def load_resource_config
      config_file = File.join(File.dirname(__FILE__), "..", "..", "..", "config", "resources.yml")

      unless File.exist?(config_file)
        raise DownloadError, "Resource configuration file not found: #{config_file}"
      end

      all_configs = YAML.load_file(config_file)
      @config = all_configs[@resource_name]

      unless @config
        available = all_configs.keys.join(", ")
        raise DownloadError, "Unknown resource: #{@resource_name}. Available: #{available}"
      end
    rescue Psych::SyntaxError => e
      raise DownloadError, "Invalid YAML in resource configuration: #{e.message}"
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
        {
          "resource" => @resource_name,
          "base_url" => @config["base_url"],
          "description" => @config["description"],
          "version" => @config["version"],
          "files" => {},
          "created_at" => Time.now.to_s,
          "updated_at" => Time.now.to_s
        }
      end
    end

    # Save manifest to disk
    def save_manifest
      @manifest["updated_at"] = Time.now.to_s
      File.write(@manifest_file, @manifest.to_yaml)
    end

    # Download a single file
    #
    # @param filename [String] Name of file to download
    # @return [Symbol] Result of download operation
    def download_file(filename)
      file_path = File.join(@resource_folder, filename)
      url = "#{@config["base_url"]}/#{filename}"

      # Check if file exists and hasn't changed
      if File.exist?(file_path) && !@force
        current_hash = calculate_file_hash(file_path)
        if @manifest["files"][filename] && @manifest["files"][filename]["hash"] == current_hash
          log "Skipping #{filename} (unchanged)"
          return DOWNLOAD_RESULTS[:skipped]
        end
      end

      log "Downloading #{filename}... ", newline: false

      begin
        uri = URI(url)
        response = Net::HTTP.get_response(uri)

        if response.code == "200"
          save_downloaded_file(file_path, response.body, filename)
          log "done"
          DOWNLOAD_RESULTS[:downloaded]
        else
          log "failed (HTTP #{response.code})"
          DOWNLOAD_RESULTS[:failed]
        end
      rescue => e
        log "failed (#{e.message})"
        DOWNLOAD_RESULTS[:failed]
      end
    end

    # Save downloaded file and update manifest
    #
    # @param file_path [String] Local file path
    # @param content [String] File content
    # @param filename [String] Original filename
    def save_downloaded_file(file_path, content, filename)
      # Ensure directory exists
      FileUtils.mkdir_p(File.dirname(file_path))
      File.write(file_path, content)

      # Extract metadata from markdown files
      metadata = extract_metadata(content, filename) if filename.end_with?(".md")

      # Update manifest
      @manifest["files"][filename] = {
        "hash" => calculate_file_hash(file_path),
        "size" => File.size(file_path),
        "downloaded_at" => Time.now.to_s
      }

      @manifest["files"][filename].merge!(metadata) if metadata
    end

    # Calculate SHA256 hash of file
    #
    # @param file_path [String] Path to file
    # @return [String] SHA256 hexdigest
    def calculate_file_hash(file_path)
      Digest::SHA256.file(file_path).hexdigest
    end

    # Extract metadata from markdown content
    #
    # @param content [String] Markdown content
    # @param filename [String] Original filename
    # @return [Hash, nil] Extracted metadata or nil
    def extract_metadata(content, filename)
      return nil unless filename.end_with?(".md")

      lines = content.lines
      metadata = {}

      # Look for title (line followed by ===)
      lines.each_with_index do |line, index|
        next if index >= lines.length - 1

        if /^=+$/.match?(lines[index + 1].strip)
          title = line.strip
          metadata["title"] = title

          # Look for description after the title
          description = extract_description(lines, index + 2)
          metadata["description"] = description if description
          break
        end
      end

      # Alternative: Look for H1 header (# Title)
      if metadata.empty?
        lines.each_with_index do |line, index|
          if line.strip =~ /^#\s+(.+)$/
            metadata["title"] = $1.strip

            # Look for description in following lines
            description = extract_description(lines, index + 1)
            metadata["description"] = description if description
            break
          end
        end
      end

      metadata.empty? ? nil : metadata
    end

    # Extract description from lines starting at given index
    #
    # @param lines [Array<String>] Content lines
    # @param start_index [Integer] Starting line index
    # @return [String, nil] Extracted description or nil
    def extract_description(lines, start_index)
      description_lines = []

      (start_index...lines.length).each do |i|
        line = lines[i].strip
        break if line =~ /^#+/ || line =~ /^-+$/ || line =~ /^=+$/
        description_lines << line unless line.empty?
      end

      return nil if description_lines.empty?
      description_lines.join(" ")
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
