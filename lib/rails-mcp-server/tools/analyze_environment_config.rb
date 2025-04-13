module RailsMcpServer
  class AnalyzeEnvironmentConfig < BaseTool
    tool_name "analyze_environment_config"

    description "Analyze environment configurations to identify inconsistencies, security issues, and missing variables across environments."

    def call
      unless current_project
        message = "No active project. Please switch to a project first."
        log(:warn, message)

        return message
      end

      # Check for required directories and files
      env_dir = File.join(active_project_path, "config", "environments")
      unless File.directory?(env_dir)
        message = "Environment configuration directory not found at config/environments."
        log(:warn, message)

        return message
      end

      # Initialize data structures
      env_files = {}
      env_settings = {}

      # 1. Parse environment files
      Dir.glob(File.join(env_dir, "*.rb")).each do |file|
        env_name = File.basename(file, ".rb")
        env_files[env_name] = file
        env_content = File.read(file)

        # Extract settings from environment files
        env_settings[env_name] = extract_env_settings(env_content)
      end

      # 2. Find ENV variable usage across the codebase
      env_vars_in_code = find_env_vars_in_codebase(active_project_path)

      # 3. Check for .env files and their variables
      dotenv_files = {}
      dotenv_vars = {}

      # Common .env file patterns
      dotenv_patterns = [
        ".env",
        ".env.development",
        ".env.test",
        ".env.production",
        ".env.local",
        ".env.development.local",
        ".env.test.local",
        ".env.production.local"
      ]

      dotenv_patterns.each do |pattern|
        file_path = File.join(active_project_path, pattern)
        if File.exist?(file_path)
          dotenv_files[pattern] = file_path
          dotenv_vars[pattern] = parse_dotenv_file(file_path)
        end
      end

      # 4. Check credentials files
      credentials_files = {}
      credentials_key_file = File.join(active_project_path, "config", "master.key")
      credentials_file = File.join(active_project_path, "config", "credentials.yml.enc")

      if File.exist?(credentials_file)
        credentials_files["credentials.yml.enc"] = credentials_file
      end

      # Environment-specific credentials files
      Dir.glob(File.join(active_project_path, "config", "credentials", "*.yml.enc")).each do |file|
        env_name = File.basename(file, ".yml.enc")
        credentials_files["credentials/#{env_name}.yml.enc"] = file
      end

      # 5. Check database configuration
      database_config_file = File.join(active_project_path, "config", "database.yml")
      database_config = {}

      if File.exist?(database_config_file)
        database_config = parse_database_config(database_config_file)
      end

      # 6. Generate findings

      # 6.1. Compare environment settings
      env_diff = compare_environment_settings(env_settings)

      # 6.2. Find missing ENV variables
      missing_env_vars = find_missing_env_vars(env_vars_in_code, dotenv_vars)

      # 6.3. Check for potential security issues
      security_findings = check_security_configuration(env_settings, database_config)

      # Format the output
      output = []

      # Environment files summary
      output << "Environment Configuration Analysis"
      output << "=================================="
      output << ""
      output << "Environment Files:"
      env_files.each do |env, file|
        output << "  - #{env}: #{file.sub("#{active_project_path}/", "")}"
      end
      output << ""

      # Environment variables summary
      output << "Environment Variables Usage:"
      output << "  Total unique ENV variables found in codebase: #{env_vars_in_code.keys.size}"
      output << ""

      # Missing ENV variables
      if missing_env_vars.any?
        output << "Missing ENV Variables:"
        missing_env_vars.each do |env_var, environments|
          output << "  - #{env_var}: Used in codebase but missing in #{environments.join(", ")}"
        end
      else
        output << "All ENV variables appear to be defined in at least one .env file."
      end
      output << ""

      # Environment differences
      if env_diff[:unique_settings].any?
        output << "Environment-Specific Settings:"
        env_diff[:unique_settings].each do |env, settings|
          output << "  #{env}:"
          settings.each do |setting|
            output << "    - #{setting}"
          end
        end
        output << ""
      end

      if env_diff[:different_values].any?
        output << "Settings with Different Values Across Environments:"
        env_diff[:different_values].each do |setting, values|
          output << "  #{setting}:"
          values.each do |env, value|
            output << "    - #{env}: #{value}"
          end
        end
        output << ""
      end

      # Credentials files
      output << "Credentials Management:"
      if credentials_files.any?
        output << "  Encrypted credentials files found:"
        credentials_files.each do |name, file|
          output << "    - #{name}"
        end

        output << if File.exist?(credentials_key_file)
          "  Master key file exists (config/master.key)"
        else
          "  Warning: No master.key file found. Credentials are likely managed through RAILS_MASTER_KEY environment variable."
        end
      else
        output << "  No encrypted credentials files found. The application may be using ENV variables exclusively."
      end
      output << ""

      # Database configuration
      output << "Database Configuration:"
      if database_config.any?
        database_config.each do |env, config|
          output << "  #{env}:"
          # Show connection details without exposing passwords
          if config["adapter"]
            output << "    - Adapter: #{config["adapter"]}"
          end
          if config["host"] && config["host"] != "localhost" && config["host"] != "127.0.0.1"
            output << "    - Host: #{config["host"]}"
          end
          if config["database"]
            output << "    - Database: #{config["database"]}"
          end

          # Check for credentials in database.yml
          if config["username"] && !config["username"].include?("ENV")
            output << "    - Warning: Database username hardcoded in database.yml"
          end
          if config["password"] && !config["password"].include?("ENV")
            output << "    - Warning: Database password hardcoded in database.yml"
          end
        end
      else
        output << "  Could not parse database configuration."
      end
      output << ""

      # Security findings
      if security_findings.any?
        output << "Security Configuration Findings:"
        security_findings.each do |finding|
          output << "  - #{finding}"
        end
        output << ""
      end

      output.join("\n")
    end

    private

    # Helper method to extract settings from environment files
    def extract_env_settings(content)
      settings = {}

      # Match configuration settings
      content.scan(/config\.([a-zA-Z0-9_.]+)\s*=\s*([^#\n]+)/) do |match|
        key = match[0].strip
        value = match[1].strip

        # Clean up the value
        value = value.chomp(";").strip

        settings[key] = value
      end

      settings
    end

    # Helper method to find ENV variable usage in the codebase
    def find_env_vars_in_codebase(project_path)
      env_vars = {}

      # Define directories to search
      search_dirs = [
        File.join(project_path, "app"),
        File.join(project_path, "config"),
        File.join(project_path, "lib")
      ]

      # Define file patterns to search
      file_patterns = ["*.rb", "*.yml", "*.erb", "*.js"]

      search_dirs.each do |dir|
        if File.directory?(dir)
          file_patterns.each do |pattern|
            Dir.glob(File.join(dir, "**", pattern)).each do |file|
              content = File.read(file)

              # Extract ENV variables
              content.scan(/ENV\s*\[\s*['"]([^'"]+)['"]\s*\]/).each do |match|
                env_var = match[0]
                env_vars[env_var] ||= []
                env_vars[env_var] << file.sub("#{project_path}/", "")
              end

              # Also match ENV['VAR'] pattern
              content.scan(/ENV\s*\.\s*\[\s*['"]([^'"]+)['"]\s*\]/).each do |match|
                env_var = match[0]
                env_vars[env_var] ||= []
                env_vars[env_var] << file.sub("#{project_path}/", "")
              end

              # Also match ENV.fetch('VAR') pattern
              content.scan(/ENV\s*\.\s*fetch\s*\(\s*['"]([^'"]+)['"]\s*/).each do |match|
                env_var = match[0]
                env_vars[env_var] ||= []
                env_vars[env_var] << file.sub("#{project_path}/", "")
              end
            rescue => e
              log(:error, "Error reading file #{file}: #{e.message}")
            end
          end
        end
      end

      env_vars
    end

    # Helper method to parse .env files
    def parse_dotenv_file(file_path)
      vars = {}

      begin
        File.readlines(file_path).each do |line| # rubocop:disable Performance/IoReadlines
          # Skip comments and empty lines
          next if line.strip.empty? || line.strip.start_with?("#")

          # Parse KEY=value pattern
          if line =~ /\A([A-Za-z0-9_]+)=(.*)\z/
            key = $1
            # Store just the existence of the variable, not its value
            vars[key] = true
          end
        end
      rescue => e
        log(:error, "Error parsing .env file #{file_path}: #{e.message}")
      end

      vars
    end

    # Helper method to parse database.yml
    def parse_database_config(file_path)
      config = {}

      begin
        # Simple YAML parsing - not handling ERB
        yaml_content = File.read(file_path)
        yaml_data = YAML.safe_load(yaml_content) || {}

        # Extract environment configurations
        %w[development test production staging].each do |env|
          config[env] = yaml_data[env] if yaml_data[env]
        end
      rescue => e
        log(:error, "Error parsing database.yml: #{e.message}")
      end

      config
    end

    # Helper method to compare environment settings
    def compare_environment_settings(env_settings)
      result = {
        unique_settings: {},
        different_values: {}
      }

      # Get all settings across all environments
      all_settings = env_settings.values.map(&:keys).flatten.uniq # rubocop:disable Performance/ChainArrayAllocation

      # Find settings unique to certain environments
      env_settings.each do |env, settings|
        unique = settings.keys - (all_settings - settings.keys)
        result[:unique_settings][env] = unique if unique.any?
      end

      # Find settings with different values across environments
      all_settings.each do |setting|
        values = {}

        env_settings.each do |env, settings|
          values[env] = settings[setting] if settings[setting]
        end

        # Only include if there are different values
        if values.values.uniq.size > 1
          result[:different_values][setting] = values
        end
      end

      result
    end

    # Helper method to find missing ENV variables
    def find_missing_env_vars(env_vars_in_code, dotenv_vars)
      missing_vars = {}

      # Check each ENV variable used in code
      env_vars_in_code.each do |var, files|
        # Environments where the variable is missing
        missing_in = []

        # Check in each .env file
        if dotenv_vars.empty?
          missing_in << "all environments (no .env files found)"
        else
          dotenv_vars.each do |env_file, vars|
            env_name = env_file.gsub(/^\.env\.?|\.local$/, "")
            env_name = "development" if env_name.empty?

            if !vars.key?(var)
              missing_in << env_name
            end
          end
        end

        missing_vars[var] = missing_in if missing_in.any?
      end

      missing_vars
    end

    # Helper method to check for security issues
    def check_security_configuration(env_settings, database_config)
      findings = []

      # Check for common security settings
      env_settings.each do |env, settings|
        # Check for secure cookies in production
        if env == "production"
          if settings["cookies.secure"] == "false"
            findings << "Production has cookies.secure = false"
          end

          if settings["session_store.secure"] == "false"
            findings << "Production has session_store.secure = false"
          end

          # Force SSL
          if settings["force_ssl"] == "false"
            findings << "Production has force_ssl = false"
          end
        end

        # Check for CSRF protection
        if settings["action_controller.default_protect_from_forgery"] == "false"
          findings << "#{env} has CSRF protection disabled"
        end
      end

      # Check for hardcoded credentials in database.yml
      database_config.each do |env, config|
        if config["username"] && !config["username"].include?("ENV")
          findings << "Database username hardcoded in database.yml for #{env}"
        end

        if config["password"] && !config["password"].include?("ENV")
          findings << "Database password hardcoded in database.yml for #{env}"
        end
      end

      findings
    end
  end
end
