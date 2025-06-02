require_relative "resource_base"

module RailsMcpServer
  class ResourceImporter < ResourceBase
    class ImportError < StandardError; end

    def initialize(resource_name, config_dir:, source_path:, force: false, verbose: false)
      @source_path = source_path
      super(resource_name, config_dir: config_dir, force: force, verbose: verbose)
      validate_source
    end

    def import
      setup_directories
      load_manifest

      log "Importing custom files from #{@source_path}..."

      results = {imported: 0, skipped: 0, failed: 0}
      files = collect_files

      if files.empty?
        log "No markdown files found"
        save_manifest
        return results
      end

      files.each do |file_path|
        result = import_file(file_path)
        results[result] += 1
      end

      save_manifest
      results
    end

    protected

    def create_manifest
      {
        "resource" => @resource_name,
        "base_url" => "local",
        "description" => "Custom imported documentation",
        "files" => {},
        "created_at" => Time.now.to_s,
        "updated_at" => Time.now.to_s
      }
    end

    def timestamp_key
      "imported_at"
    end

    private

    def validate_source
      raise ImportError, "Source not found: #{@source_path}" unless File.exist?(@source_path)
      raise ImportError, "Source not readable: #{@source_path}" unless File.readable?(@source_path)
    end

    def collect_files
      if File.file?(@source_path)
        markdown?(@source_path) ? [@source_path] : []
      elsif File.directory?(@source_path)
        Dir.glob(File.join(@source_path, "*.md")).select { |f| File.file?(f) }.sort # rubocop:disable Performance/ChainArrayAllocation
      else
        []
      end
    end

    def markdown?(file_path)
      File.extname(file_path).casecmp(".md").zero?
    end

    def import_file(file_path)
      original_filename = File.basename(file_path)
      normalized_filename = normalize_filename(original_filename)
      destination_path = File.join(@resource_folder, normalized_filename)

      # Skip if unchanged
      if !@force && file_unchanged?(normalized_filename, file_path)
        log "Skipping #{original_filename} (unchanged)"
        return :skipped
      end

      log "Importing #{original_filename} -> #{normalized_filename}... ", newline: false

      begin
        FileUtils.cp(file_path, destination_path)
        save_file_to_manifest(normalized_filename, destination_path,
          {"original_filename" => original_filename})
        log "done"
        :imported
      rescue => e
        log "failed (#{e.message})"
        :failed
      end
    end

    def normalize_filename(filename)
      basename = File.basename(filename, ".md")
      extension = File.extname(filename)

      normalized = basename.downcase
        .gsub(/[^a-z0-9_\-.]/, "_")
        .squeeze("_")
        .gsub(/^_+|_+$/, "")

      normalized = "untitled" if normalized.empty?
      "#{normalized}#{extension}"
    end
  end
end
