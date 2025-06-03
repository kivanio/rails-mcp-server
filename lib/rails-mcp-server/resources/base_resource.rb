module RailsMcpServer
  class BaseResource < FastMcp::Resource
    extend Forwardable

    def_delegators :RailsMcpServer, :log, :config_dir
  end
end
