module RailsMcpServer
  module Extensions
    # Extension module to add URI templating capabilities to FastMcp::Resource
    # Uses module prepending for clean method override behavior
    module ResourceTemplating
      # Class methods to be prepended to the singleton class
      module ClassMethods
        attr_reader :template_params

        def variabilized_uri(params = {})
          addressable_template.partial_expand(params).pattern
        end

        def addressable_template
          @addressable_template ||= Addressable::Template.new(uri)
        end

        def template_variables
          addressable_template.variables
        end

        def templated?
          template_variables.any?
        end

        def non_templated?
          !templated?
        end

        def match(uri)
          addressable_template.match(uri)
        end

        def initialize_from_uri(uri)
          new(params_from_uri(uri))
        end

        def params_from_uri(uri)
          match(uri).mapping.transform_keys(&:to_sym)
        end

        def instance(uri = self.uri)
          @instances ||= {}
          @instances[uri] ||= begin
            resource_class = Class.new(self)
            params = params_from_uri(uri)
            resource_class.instance_variable_set(:@params, params)

            resource_class.define_singleton_method(:instance) do
              @instance ||= begin
                instance = new
                instance.instance_variable_set(:@params, params)
                instance
              end
            end

            resource_class.instance
          end
        end

        def params
          @params || {}
        end

        def name
          return resource_name if resource_name
          super
        end

        def metadata
          if templated?
            {
              uriTemplate: uri,
              name: resource_name,
              description: description,
              mimeType: mime_type
            }.compact
          else
            super
          end
        end
      end

      # Instance methods to be prepended
      module InstanceMethods
        def initialize
          @params = self.class.params
          super if defined?(super)
        end

        def params
          @params || self.class.params
        end

        def name
          self.class.resource_name
        end
      end

      # Called when this module is prepended to a class
      def self.prepended(base)
        base.singleton_class.prepend(ClassMethods)
        base.prepend(InstanceMethods)
      end
    end

    # Main setup class for resource extensions
    class ResourceExtensionSetup
      class << self
        def setup!
          return if @setup_complete

          ensure_dependencies_loaded!
          apply_extensions!

          @setup_complete = true
          RailsMcpServer.log(:info, "FastMcp::Resource extensions loaded successfully")
        rescue => e
          RailsMcpServer.log(:error, "Failed to setup resource extensions: #{e.message}")
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
          # Check that FastMcp::Resource exists
          unless defined?(FastMcp::Resource)
            begin
              require "fast-mcp"
            rescue LoadError => e
              raise LoadError, "fast-mcp gem is required but not available. Ensure it's in your Gemfile: #{e.message}"
            end
          end

          # Verify the expected interface exists
          unless FastMcp::Resource.respond_to?(:uri)
            raise "FastMcp::Resource doesn't have expected interface. Check fast-mcp gem version."
          end

          # Load addressable template dependency
          begin
            require "addressable/template"
          rescue LoadError => e
            raise LoadError, "addressable gem is required for URI templating: #{e.message}"
          end

          # Optional: Version checking
          if defined?(FastMcp::VERSION)
            version = Gem::Version.new(FastMcp::VERSION)
            minimum_version = Gem::Version.new("1.4.0")

            if version < minimum_version
              RailsMcpServer.log(:warn, "FastMcp version #{FastMcp::VERSION} detected. Extensions tested with #{minimum_version}+")
            end
          end
        end

        def apply_extensions!
          # Apply extensions to FastMcp::Resource
          FastMcp::Resource.prepend(ResourceTemplating)

          # Also ensure our BaseResource gets the extensions
          if defined?(RailsMcpServer::BaseResource)
            # BaseResource already inherits from FastMcp::Resource, so it gets extensions automatically
            RailsMcpServer.log(:debug, "BaseResource will inherit templating extensions")
          end

          # Setup server extensions as well
          RailsMcpServer::Extensions::ServerExtensionSetup.setup!
        end
      end
    end
  end
end
