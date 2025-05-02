module RailsMcpServer
  class GetSchema < BaseTool
    tool_name "get_schema"

    description "Retrieve database schema information for the Rails application. Without parameters, returns all tables and the complete schema.rb. With a table name, returns detailed column information including data types, constraints, and foreign keys for that specific table."

    arguments do
      optional(:table_name).filled(:string).description("Database table name to get detailed schema information for (e.g., 'users', 'products'). Use snake_case, plural form. If omitted, returns complete database schema.")
    end

    def call(table_name: nil)
      unless current_project
        message = "No active project. Please switch to a project first."
        log(:warn, message)

        return message
      end

      if table_name
        log(:info, "Getting schema for table: #{table_name}")

        # Execute the Rails schema command for a specific table
        schema_output = RailsMcpServer::RunProcess.execute_rails_command(
          active_project_path,
          "bin/rails runner \"require 'active_record'; puts ActiveRecord::Base.connection.columns('#{table_name}').map{|c| [c.name, c.type, c.null, c.default].inspect}.join('\\n')\""
        )

        if schema_output.strip.empty?
          message = "Table '#{table_name}' not found or has no columns."
          log(:warn, message)

          return message
        end

        # Parse the column information
        columns = schema_output.strip.split("\\n").map do |column_info|
          eval(column_info) # This is safe because we're generating the string ourselves # rubocop:disable Security/Eval
        end

        # Format the output
        formatted_columns = columns.map do |name, type, nullable, default|
          "#{name} (#{type})#{nullable ? ", nullable" : ""}#{default ? ", default: #{default}" : ""}"
        end

        output = <<~SCHEMA
          Table: #{table_name}

          Columns:
          #{formatted_columns.join("\n")}
        SCHEMA

        # Try to get foreign keys
        begin
          fk_output = RailsMcpServer::RunProcess.execute_rails_command(
            active_project_path,
            "bin/rails runner \"require 'active_record'; puts ActiveRecord::Base.connection.foreign_keys('#{table_name}').map{|fk| [fk.from_table, fk.to_table, fk.column, fk.primary_key].inspect}.join('\n')\""
          )

          unless fk_output.strip.empty?
            foreign_keys = fk_output.strip.split("\n").map do |fk_info|
              eval(fk_info) # This is safe because we're generating the string ourselves # rubocop:disable Security/Eval
            end

            formatted_fks = foreign_keys.map do |from_table, to_table, column, primary_key|
              "#{column} -> #{to_table}.#{primary_key}"
            end

            output += <<~FK

              Foreign Keys:
              #{formatted_fks.join("\n")}
            FK
          end
        rescue => e
          log(:warn, "Error fetching foreign keys: #{e.message}")
        end

        output
      else
        log(:info, "Getting full schema")

        # Execute the Rails schema:dump command
        # First, check if we need to create the schema file
        schema_file = File.join(active_project_path, "db", "schema.rb")
        unless File.exist?(schema_file)
          log(:info, "Schema file not found, attempting to generate it")
          RailsMcpServer::RunProcess.execute_rails_command(active_project_path, "db:schema:dump")
        end

        if File.exist?(schema_file)
          # Read the schema file
          schema_content = File.read(schema_file)

          # Try to get table list
          tables_output = RailsMcpServer::RunProcess.execute_rails_command(
            active_project_path,
            "bin/rails runner \"require 'active_record'; puts ActiveRecord::Base.connection.tables.sort.join('\n')\""
          )

          tables = tables_output.strip.split("\n")

          <<~SCHEMA
            Database Schema

            Tables:
            #{tables.join("\n")}

            Schema Definition:
            ```ruby
            #{schema_content}
            ```
          SCHEMA
        else
          # If we can't get the schema file, try to get the table list
          tables_output = RailsMcpServer::RunProcess.execute_rails_command(
            active_project_path,
            "bin/rails runner \"require 'active_record'; puts ActiveRecord::Base.connection.tables.sort.join('\n')\""
          )

          if tables_output.strip.empty?
            message = "Could not retrieve schema information. Try running 'rails db:schema:dump' in your project first."
            log(:warn, message)

            return message
          end

          tables = tables_output.strip.split("\n")

          <<~SCHEMA
            Database Schema

            Tables:
            #{tables.join("\n")}

            Note: Full schema definition is not available. Run 'rails db:schema:dump' to generate the schema.rb file.
          SCHEMA
        end
      end
    end
  end
end
