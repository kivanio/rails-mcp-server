module RailsMcpServer
  # Module defining the contract that guide resources must implement
  module GuideFrameworkContract
    def self.included(base)
      base.extend(ClassMethods)
    end

    module ClassMethods
      # Validate that required methods are implemented
      def validate_contract!
        required_methods = [:framework_name, :resource_directory, :download_command]

        required_methods.each do |method|
          unless method_defined?(method)
            raise NotImplementedError, "#{self} must implement ##{method}"
          end
        end
      end
    end

    protected

    # Abstract methods that must be implemented by including classes
    def framework_name
      raise NotImplementedError, "#{self.class} must implement #framework_name"
    end

    def resource_directory
      raise NotImplementedError, "#{self.class} must implement #resource_directory"
    end

    def download_command
      raise NotImplementedError, "#{self.class} must implement #download_command"
    end

    # Optional methods with default implementations
    def supports_sections?
      false
    end

    # Optional method for list resources
    def example_guides
      []
    end

    # Optional framework-specific methods (can be overridden)
    def framework_specific_filenames(normalized_guide_name)
      []
    end

    def framework_specific_section(filename)
      "Documentation"
    end

    # Utility method to check if this is a list resource
    def list_resource?
      respond_to?(:example_guides)
    end

    # Utility method to check if this is a single guide resource
    def single_guide_resource?
      respond_to?(:params) && params.key?(:guide_name)
    end
  end
end
