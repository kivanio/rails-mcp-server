require_relative "lib/rails-mcp-server/version"

Gem::Specification.new do |spec|
  spec.name = "rails-mcp-server"
  spec.version = RailsMcpServer::VERSION
  spec.authors = ["Mario Alberto Chávez Cárdenas"]
  spec.email = ["mario.chavez@gmail.com"]

  spec.summary = "MCP server for Rails projects"
  spec.description = "A Ruby implementation of Model Context Protocol server for Rails projects"
  spec.homepage = "https://github.com/maquina-app/rails-mcp-server"
  spec.license = "MIT"
  spec.required_ruby_version = Gem::Requirement.new(">= 2.5.0")

  spec.metadata["allowed_push_host"] = "https://rubygems.org"
  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage

  spec.files = Dir.glob("{lib,exe}/**/*") + %w[LICENSE.txt README.md]
  spec.bindir = "exe"
  spec.executables = ["rails-mcp-server", "rails-mcp-setup-claude"]
  spec.require_paths = ["lib"]

  spec.add_dependency "mcp-rb"
  spec.add_dependency "logger"
  spec.add_development_dependency "standard"
end
