# Rails MCP Server

A Ruby implementation of a Model Context Protocol (MCP) server for Rails projects. This server allows LLMs (Large Language Models) to interact with Rails projects through the Model Context Protocol.

## What is MCP?

The Model Context Protocol (MCP) is a standardized way for AI models to interact with their environment. It defines a structured method for models to request and use tools, access resources, and maintain context during interactions.

This Rails MCP Server implements the MCP specification to give AI models access to Rails projects for code analysis, exploration, and assistance.

## Features

- Manage multiple Rails projects
- Browse project files and structures
- View Rails routes
- Inspect model information
- Get database schema information
- Follow the Model Context Protocol standard

## Installation

Install the gem:

```bash
gem install rails-mcp-server
```

After installation, the `rails-mcp-server` and `rails-mcp-setup-claude` executables will be available in your PATH.

## Configuration

The Rails MCP Server follows the XDG Base Directory Specification for configuration files:

- On macOS: `$XDG_CONFIG_HOME/rails-mcp` or `~/.config/rails-mcp` if XDG_CONFIG_HOME is not set
- On Windows: `%APPDATA%\rails-mcp`

The server will automatically create these directories and an empty `projects.yml` file the first time it runs.

To configure your projects:

1. Edit the `projects.yml` file in your config directory to include your Rails projects:

```yaml
store: "~/projects/store"
blog: "~/projects/rails-blog"
```

Each key in the YAML file is a project name (which will be used with the `switch_project` tool), and each value is the path to the project directory.

## Claude Desktop Integration

The Rails MCP Server can be used with Claude Desktop. There are two options to set this up:

### Option 1: Use the setup script (recommended)

Run the setup script which will automatically configure Claude Desktop and set up the proper XDG-compliant directory structure:

```bash
rails-mcp-setup-claude
```

The script will:

- Create the appropriate config directory for your platform
- Create an empty `projects.yml` file if it doesn't exist
- Update the Claude Desktop configuration

After running the script, restart Claude Desktop to apply the changes.

### Option 2: Manual configuration

1. Create the appropriate config directory for your platform:
   - macOS: `$XDG_CONFIG_HOME/rails-mcp` or `~/.config/rails-mcp`
   - Windows: `%APPDATA%\rails-mcp`

2. Create a `projects.yml` file in that directory with your Rails projects.

3. Find or create the Claude Desktop configuration file:
   - macOS: `~/Library/Application Support/Claude/claude_desktop_config.json`
   - Windows: `%APPDATA%\Claude\claude_desktop_config.json`

4. Add or update the MCP server configuration:

```json
{
  "mcpServers": {
    "railsMcpServer": {
      "command": "ruby",
      "args": ["/full/path/to/rails-mcp-server/exe/rails-mcp-server"] 
    }
  }
}
```

5. Restart Claude Desktop to apply the changes.

### Ruby Version Manager Users

Claude Desktop launches the MCP server using your system's default Ruby environment, bypassing version manager initialization (e.g., rbenv, RVM). The MCP server needs to use the same Ruby version where it was installed, as MCP server startup failures can occur when using an incompatible Ruby version.

If you are using a Ruby version manager such as rbenv, you can create a symbolic link to your Ruby shim to ensure the correct version is used:

```

sudo ln -s /home/your_user/.rbenv/shims/ruby /usr/local/bin/ruby

```

Replace "/home/your_user/.rbenv/shims/ruby" with your actual path for the Ruby shim.

## Usage

Start the server:

```bash
rails-mcp-server
```

### Logging Options

The server logs to a file in the `./log` directory by default. You can customize logging with these options:

```bash
# Set the log level (debug, info, warn, error, fatal)
rails-mcp-server --log-level debug
```

## How the Server Works

The Rails MCP Server implements the Model Context Protocol over standard input/output (stdio). It:

1. Reads JSON-RPC 2.0 requests from standard input
2. Processes the requests using the appropriate tools
3. Returns JSON-RPC 2.0 responses to standard output

Each request includes a sequence number to match requests with responses, as defined in the MCP specification.

## Available Tools

The server provides the following tools for interacting with Rails projects:

### 1. `switch_project`

Switch the active Rails project.

**Parameters:**

- `project_name`: (String, required) Name of the project to switch to, as defined in the projects.yml file

**Example:**

```json
{
  "jsonrpc": "2.0",
  "id": "123",
  "method": "tools/call",
  "params": {
    "name": "switch_project",
    "arguments": {
      "project_name": "blog"
    }
  }
}
```

**Description:** Change the active Rails project to interact with a different codebase. Must be called before using other tools. Available projects are defined in the projects.yml configuration file.

Examples:

```
Can you switch to the "store" project so we can explore it?
```

```
I'd like to analyze my "blog" application. Please switch to that project first.
```

```
Switch to the "ecommerce" project and give me a summary of the codebase.
```

### 2. `get_project_info`

Get information about the current Rails project, including version, directory structure, and configuration.

**Parameters:** None

**Example:**

```json
{
  "jsonrpc": "2.0",
  "id": "124",
  "method": "tools/call",
  "params": {
    "name": "get_project_info",
    "arguments": {}
  }
}
```

**Description:** Retrieve comprehensive information about the current Rails project, including Rails version, directory structure, API-only status, and overall project organization.

Examples:

```
Now that we're in the blog project, can you give me an overview of the project structure and Rails version?
```

```
Tell me about this Rails application. What version is it running and how is it organized?
```

```
I'd like to understand the high-level architecture of this project. Can you provide the project information?
```

### 3. `list_files`

List files in the Rails project, with optional directory path and pattern filtering.

**Parameters:**

- `directory`: (String, optional) Directory path relative to the project root
- `pattern`: (String, optional) File pattern to match (e.g., "*.rb")

**Example:**

```json
{
  "jsonrpc": "2.0",
  "id": "125",
  "method": "tools/call",
  "params": {
    "name": "list_files",
    "arguments": {
      "directory": "app/models",
      "pattern": "*.rb"
    }
  }
}
```

**Description:** List files in the Rails project matching specific criteria. Use this to explore project directories or locate specific file types.

Examples:

```
Can you list all the model files in this project?
```

```
Show me all the controller files in the app/controllers directory.
```

```
I need to see all the view templates in the users section. Can you list the files in app/views/users?
```

```
List all the JavaScript files in the app/javascript directory.
```

### 4. `get_file`

Get the content of a file in the Rails project with syntax highlighting.

**Parameters:**

- `path`: (String, required) File path relative to the project root

**Example:**

```json
{
  "jsonrpc": "2.0",
  "id": "126",
  "method": "tools/call",
  "params": {
    "name": "get_file",
    "arguments": {
      "path": "app/models/user.rb"
    }
  }
}
```

**Description:** Retrieve the complete content of a specific file with syntax highlighting.

Examples:

```
Can you show me the content of the User model file?
```

```
I need to see what's in app/controllers/products_controller.rb. Can you retrieve that file?
```

```
Please show me the application.rb file so I can check the configuration settings.
```

```
I'd like to examine the routes file. Can you display the content of config/routes.rb?
```

### 5. `get_routes`

Get the routes defined in the Rails project.

**Parameters:** None

**Example:**

```json
{
  "jsonrpc": "2.0",
  "id": "127",
  "method": "tools/call",
  "params": {
    "name": "get_routes",
    "arguments": {}
  }
}
```

**Description:** Retrieve all HTTP routes defined in the Rails application with their associated controllers and actions.

Examples:

```
Can you show me all the routes defined in this application?
```

```
I need to understand the API endpoints available in this project. Can you list the routes?
```

```
Show me the routing configuration for this Rails app so I can see how the URLs are structured.
```

### 6. `get_models`

Get information about the models in the Rails project, including schema, associations, and definitions.

**Parameters:**

- `model_name`: (String, optional) Name of a specific model to get information for

**Example:**

```json
{
  "jsonrpc": "2.0",
  "id": "128",
  "method": "tools/call",
  "params": {
    "name": "get_models",
    "arguments": {
      "model_name": "User"
    }
  }
}
```

**Description:** Retrieve detailed information about Active Record models in the project.

Examples:

```
Can you list all the models in this Rails project?
```

```
I'd like to understand the User model in detail. Can you show me its schema, associations, and code?
```

```
Show me the Product model's definition, including its relationships with other models.
```

```
What are all the models in this application, and can you then show me details for the Order model specifically?
```

### 7. `get_schema`

Get the database schema for the Rails project or for a specific table.

**Parameters:**

- `table_name`: (String, optional) Name of a specific table to get schema for

**Example:**

```json
{
  "jsonrpc": "2.0",
  "id": "129",
  "method": "tools/call",
  "params": {
    "name": "get_schema",
    "arguments": {
      "table_name": "users"
    }
  }
}
```

**Description:** Retrieve database schema information for the Rails application.

Examples:

```
Can you show me the complete database schema for this Rails application?
```

```
I'd like to see the structure of the users table. Can you retrieve that schema information?
```

```
Show me the columns and their data types in the products table.
```

```
I need to understand the database design. Can you first list all tables and then show me details for the orders table?
```

## Integration with LLM Clients

This server is designed to be integrated with LLM clients that support the Model Context Protocol, such as Claude Desktop or other MCP-compatible applications.

To use with an MCP client:

1. Start the Rails MCP Server
2. Connect your MCP-compatible client to the server
3. The client will be able to use the available tools to interact with your Rails projects

## Manual Testing

You can manually test the server by sending JSON-RPC requests to its standard input:

```bash
echo '0 {"jsonrpc":"2.0","id":"test-123","method":"ping"}' | rails-mcp-server
```

Expected response:

```
0 {"jsonrpc":"2.0","id":"test-123","result":{"version":"1.0.0"}}
```

Or test multiple commands in sequence:

```bash
(echo '0 {"jsonrpc":"2.0","id":"test-123","method":"tools/list"}'; sleep 1; echo '1 {"jsonrpc":"2.0","id":"test-456","method":"tools/call","params":{"name":"switch_project","arguments":{"project_name":"blog"}}}') | rails-mcp-server
```

You can also use `jq` to parse the output and format it nicely:

```bash
echo '0 {"jsonrpc":"2.0","id":"list-tools","method":"tools/list"}' | rails-mcp-server | sed 's/^[0-9]* //' | jq '.result.tools'
```

## License

This Rails MCP server is released under the MIT License, a permissive open-source license that allows for free use, modification, distribution, and private use.

Copyright (c) 2025 Mario Alberto Chávez Cárdenas

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

## Contributing

Bug reports and pull requests are welcome on GitHub at <https://github.com/maquina-app/rails-mcp-server>.
