module RailsMcpServer
  module Extensions
    # Extension module to add any missing templated resource support to FastMcp::Server
    # This version of the server already has most templated resource functionality
    module ServerTemplating
      # Instance methods to be prepended
      module InstanceMethods
        # The target server already has most functionality, but we can add defensive checks
        def read_resource(uri)
          # Handle both hash-based and array-based resource storage
          if @resources.is_a?(Hash)
            # First try exact match (hash lookup)
            exact_match = @resources[uri]
            return exact_match if exact_match

            # Then try templated resource matching
            @resources.values.find { |r| r.respond_to?(:match) && r.match(uri) }
          else
            # Array-based storage (original target server behavior)
            resource = @resources.find { |r| r.respond_to?(:match) && r.match(uri) }

            # Fallback: if no templated match, try exact URI match for backward compatibility
            resource ||= @resources.find { |r| r.respond_to?(:uri) && r.uri == uri }

            resource
          end
        end

        # Add some defensive programming to handle_resources_read
        def handle_resources_read(params, id)
          uri = params["uri"]

          return send_error(-32_602, "Invalid params: missing resource URI", id) unless uri

          @logger.debug("Looking for resource with URI: #{uri}")

          begin
            resource = read_resource(uri)
            return send_error(-32_602, "Resource not found: #{uri}", id) unless resource

            # Defensive check for templated method
            is_templated = resource.respond_to?(:templated?) ? resource.templated? : false
            @logger.debug("Found resource: #{resource.respond_to?(:resource_name) ? resource.resource_name : resource.name}, templated: #{is_templated}")

            base_content = {uri: uri}
            base_content[:mimeType] = resource.mime_type if resource.mime_type

            # Handle both templated and non-templated resources
            resource_instance = if is_templated && resource.respond_to?(:instance)
              resource.instance(uri)
            else
              # Fallback for non-templated resources or resources without instance method
              resource.respond_to?(:instance) ? resource.instance : resource
            end

            # Defensive check for params method
            if resource_instance.respond_to?(:params)
              @logger.debug("Resource instance params: #{resource_instance.params.inspect}")
            end

            result = if resource_instance.respond_to?(:binary?) && resource_instance.binary?
              {
                contents: [base_content.merge(blob: Base64.strict_encode64(resource_instance.content))]
              }
            else
              {
                contents: [base_content.merge(text: resource_instance.content)]
              }
            end

            send_result(result, id)
          rescue => e
            @logger.error("Error reading resource: #{e.message}")
            @logger.error(e.backtrace.join("\n"))
            send_error(-32_600, "Internal error reading resource: #{e.message}", id)
          end
        end

        # The target server already has these methods, but we can add defensive checks
        def handle_resources_list(id)
          # Handle both hash-based and array-based resource storage
          resources_collection = @resources.is_a?(Hash) ? @resources.values : @resources

          resources_list = resources_collection.select do |resource|
            !resource.respond_to?(:templated?) || resource.non_templated?
          end.map(&:metadata) # rubocop:disable Performance/ChainArrayAllocation

          send_result({resources: resources_list}, id)
        end

        def handle_resources_templates_list(id)
          @logger.debug("Handling resources/templates/list request")

          # Handle both hash-based and array-based resource storage
          resources_collection = @resources.is_a?(Hash) ? @resources.values : @resources

          templated_resources_list = resources_collection.select do |resource|
            resource.respond_to?(:templated?) && resource.templated?
          end.map do |resource| # rubocop:disable Performance/ChainArrayAllocation
            metadata = resource.metadata
            @logger.debug("Template resource metadata: #{metadata}")
            metadata
          end

          @logger.info("Returning #{templated_resources_list.length} templated resources")
          send_result({resourceTemplates: templated_resources_list}, id)
        end

        # Override handle_request to ensure resources/templates/list endpoint is available
        def handle_request(*args)
          # Extract arguments - handle different signatures
          if args.length == 2
            json_str, headers = args
            headers ||= {}
          else
            json_str = args[0]
            headers = {}
          end

          begin
            request = JSON.parse(json_str)
          rescue JSON::ParserError, TypeError
            return send_error(-32_600, "Invalid Request", nil)
          end

          @logger.debug("Received request: #{request.inspect}")

          # Check if it's a valid JSON-RPC 2.0 request
          unless request["jsonrpc"] == "2.0" && request["method"]
            return send_error(-32_600, "Invalid Request", request["id"])
          end

          method = request["method"]
          params = request["params"] || {}
          id = request["id"]

          # Handle the resources/templates/list endpoint specifically since it might not exist in original
          if method == "resources/templates/list"
            @logger.debug("Handling resources/templates/list via extension")
            return handle_resources_templates_list(id)
          end

          # For all other methods, call the original implementation
          begin
            super
          rescue NoMethodError => e
            # If super doesn't work, provide our own fallback
            @logger.debug("Original handle_request not available, using fallback: #{e.message}")
            handle_request_fallback(method, params, id, headers)
          end
        rescue => e
          @logger.error("Error handling request: #{e.message}, #{e.backtrace.join("\n")}")
          send_error(-32_600, "Internal error: #{e.message}", id)
        end

        private

        def handle_request_fallback(method, params, id, headers)
          @logger.debug("Using fallback handler for method: #{method}")

          case method
          when "ping"
            send_result({}, id)
          when "initialize"
            handle_initialize(params, id)
          when "notifications/initialized"
            handle_initialized_notification
          when "tools/list"
            handle_tools_list(id)
          when "tools/call"
            # Handle different method signatures for tools/call
            if method(:handle_tools_call).arity == 3
              handle_tools_call(params, headers, id)
            else
              handle_tools_call(params, id)
            end
          when "resources/list"
            handle_resources_list(id)
          when "resources/templates/list"
            handle_resources_templates_list(id)
          when "resources/read"
            handle_resources_read(params, id)
          when "resources/subscribe"
            handle_resources_subscribe(params, id)
          when "resources/unsubscribe"
            handle_resources_unsubscribe(params, id)
          else
            send_error(-32_601, "Method not found: #{method}", id)
          end
        end

        # Add defensive programming to resource subscription methods
        def handle_resources_subscribe(params, id)
          return unless @client_initialized

          uri = params["uri"]

          unless uri
            send_error(-32_602, "Invalid params: missing resource URI", id)
            return
          end

          # Use the read_resource method which supports templated resources
          resource = read_resource(uri)
          return send_error(-32_602, "Resource not found: #{uri}", id) unless resource

          # Add to subscriptions
          @resource_subscriptions[uri] ||= []
          @resource_subscriptions[uri] << id

          send_result({subscribed: true}, id)
        end

        # Enhanced logging for resource registration
        def register_resource(resource)
          # Handle both hash-based and array-based resource storage
          if @resources.is_a?(Hash)
            @resources[resource.uri] = resource
          else
            @resources << resource
          end

          resource_name = if resource.respond_to?(:resource_name)
            resource.resource_name
          else
            (resource.respond_to?(:name) ? resource.name : "Unknown")
          end
          is_templated = resource.respond_to?(:templated?) ? resource.templated? : false

          @logger.debug("Registered resource: #{resource_name} (#{resource.uri}) - Templated: #{is_templated}")
          resource.server = self if resource.respond_to?(:server=)

          # Notify subscribers about the list change
          notify_resource_list_changed if @transport

          resource
        end
      end

      # Called when this module is prepended to a class
      def self.prepended(base)
        base.prepend(InstanceMethods)
      end
    end

    # Setup class for server extensions
    class ServerExtensionSetup
      class << self
        def setup!
          return if @setup_complete

          ensure_dependencies_loaded!
          check_server_compatibility!
          apply_extensions_if_needed!

          @setup_complete = true
          RailsMcpServer.log(:info, "FastMcp::Server extensions checked and applied if needed")
        rescue => e
          RailsMcpServer.log(:error, "Failed to setup server extensions: #{e.message}")
          raise
        end

        def reset!
          @setup_complete = false
        end

        def setup_complete?
          @setup_complete || false
        end

        private

        def ensure_dependencies_loaded!
          # Check that FastMcp::Server exists
          unless defined?(FastMcp::Server)
            begin
              require "fast-mcp"
            rescue LoadError => e
              raise LoadError, "fast-mcp gem is required but not available: #{e.message}"
            end
          end

          # Verify the expected interface exists
          unless FastMcp::Server.instance_methods.include?(:read_resource)
            raise "FastMcp::Server doesn't have expected read_resource method. Check fast-mcp gem version."
          end

          # Check handle_request method signature
          handle_request_method = FastMcp::Server.instance_method(:handle_request)
          arity = handle_request_method.arity
          RailsMcpServer.log(:debug, "FastMcp::Server#handle_request arity: #{arity}")

          # Check if resources/templates/list is already supported
          test_server = FastMcp::Server.new(name: "test", version: "1.0.0")
          has_templates_method = test_server.respond_to?(:handle_resources_templates_list)
          RailsMcpServer.log(:debug, "Original server has handle_resources_templates_list: #{has_templates_method}")
        end

        def check_server_compatibility!
          # Check if the server already has templated resource support
          server_instance = FastMcp::Server.new(name: "test", version: "1.0.0")

          @server_has_templates = server_instance.respond_to?(:handle_resources_templates_list)
          @server_has_advanced_read = begin
            # Check if read_resource method body includes 'match'
            method_source = FastMcp::Server.instance_method(:read_resource).source_location
            method_source ? true : false
          rescue
            false
          end

          RailsMcpServer.log(:debug, "Server template support detected: #{@server_has_templates}")
          RailsMcpServer.log(:debug, "Server advanced read support detected: #{@server_has_advanced_read}")
        end

        def apply_extensions_if_needed!
          # Always apply extensions to ensure resources/templates/list endpoint is available
          # The MCP inspector error shows this endpoint is missing
          RailsMcpServer.log(:info, "Applying server extensions to ensure full MCP compliance")
          FastMcp::Server.prepend(ServerTemplating)

          # Verify the extension was applied by checking if our methods are available
          test_server = FastMcp::Server.new(name: "test", version: "1.0.0")
          has_templates_list = test_server.respond_to?(:handle_resources_templates_list)
          RailsMcpServer.log(:info, "Server extension verification - handle_resources_templates_list available: #{has_templates_list}")
        rescue => e
          RailsMcpServer.log(:error, "Error applying server extensions: #{e.message}")
          raise
        end
      end
    end
  end
end
