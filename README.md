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
- Analyze controller-view relationships
- Analyze environment configurations
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

### Starting the server

The Rails MCP Server can run in two modes:

1. **STDIO mode (default)**: Communicates over standard input/output for direct integration with clients like Claude Desktop.
2. **HTTP mode**: Runs as an HTTP server with JSON-RPC and Server-Sent Events (SSE) endpoints.

```bash
# Start in default STDIO mode
rails-mcp-server

# Start in HTTP mode on the default port (6029)
rails-mcp-server --mode http

# Start in HTTP mode on a custom port
rails-mcp-server --mode http -p 8080
```

When running in HTTP mode, the server provides two endpoints:

- JSON-RPC endpoint: `http://localhost:<port>/mcp/messages`
- SSE endpoint: `http://localhost:<port>/mcp/sse`

### Logging Options

The server logs to a file in the `./log` directory by default. You can customize logging with these options:

```bash
# Set the log level (debug, info, error)
rails-mcp-server --log-level debug
```

## How the Server Works

The Rails MCP Server implements the Model Context Protocol using either:

- **STDIO mode**: Reads JSON-RPC 2.0 requests from standard input and returns responses to standard output.
- **HTTP mode**: Provides HTTP endpoints for JSON-RPC 2.0 requests and Server-Sent Events.

Each request includes a sequence number to match requests with responses, as defined in the MCP specification.

## Available Tools

The server provides the following tools for interacting with Rails projects:

### 1. `switch_project`

**Description:** Change the active Rails project to interact with a different codebase. Must be called before using other tools. Available projects are defined in the projects.yml configuration file.

**Parameters:**

- `project_name`: (String, required) Name of the project to switch to, as defined in the projects.yml file

#### Examples

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

**Description:** Retrieve comprehensive information about the current Rails project, including Rails version, directory structure, API-only status, and overall project organization. Useful for initial project exploration and understanding the codebase structure.

**Parameters:** None

#### Examples

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

**Description:** List files in the Rails project matching specific criteria. Use this to explore project directories or locate specific file types. If no parameters are provided, lists files in the project root.

**Parameters:**

- `directory`: (String, optional) Directory path relative to the project root (e.g., 'app/models', 'config')
- `pattern`: (String, optional) File pattern using glob syntax (e.g., '.rb' for Ruby files, '.erb' for ERB templates)

#### Examples

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

**Description:** Retrieve the complete content of a specific file with syntax highlighting. Use this to examine implementation details, configurations, or any text file in the project.

**Parameters:**

- `path`: (String, required) File path relative to the project root (e.g., 'app/models/user.rb', 'config/routes.rb')

#### Examples

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

**Description:** Retrieve all HTTP routes defined in the Rails application with their associated controllers and actions. Equivalent to running 'rails routes' command. This helps understand the API endpoints or page URLs available in the application.

**Parameters:** None

#### Examples

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

**Description:** Retrieve detailed information about Active Record models in the project. When called without parameters, lists all model files. When a specific model is specified, returns its schema, associations (has_many, belongs_to, has_one), and complete source code.

**Parameters:**

- `model_name`: (String, optional) Class name of a specific model to get detailed information for (e.g., 'User', 'Product'). Use CamelCase, not snake_case.

#### Examples

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

**Description:** Retrieve database schema information for the Rails application. Without parameters, returns all tables and the complete schema.rb. With a table name, returns detailed column information including data types, constraints, and foreign keys for that specific table.

**Parameters:**

- `table_name`: (String, optional) Database table name to get detailed schema information for (e.g., 'users', 'products'). Use snake_case, plural form.

#### Examples

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

### 8. `analyze_controller_views`

**Description:** Analyze the relationships between controllers, their actions, and corresponding views to understand the application's UI flow.

**Parameters:**

- `controller_name`: (String, optional) Name of a specific controller to analyze (e.g., 'UsersController' or 'users'). If omitted, all controllers will be analyzed.

#### Examples

```
Can you analyze the Users controller and its views to help me understand the UI flow?
```

### 9. `analyze_environment_config`

**Description:** Analyze environment configurations to identify inconsistencies, security issues, and missing variables across environments.

**Parameters:** None

#### Examples

```
Can you analyze the environment configurations to find any security issues or missing environment variables?
```

## Integration with LLM Clients

This server is designed to be integrated with LLM clients that support the Model Context Protocol, such as Claude Desktop or other MCP-compatible applications.
To use with an MCP client:

1. Start the Rails MCP Server (it will use STDIO mode by default)
1. Connect your MCP-compatible client to the server
1. The client will be able to use the available tools to interact with your Rails projects

## Testing and Debugging

The easiest way to test and debug the Rails MCP Server is by using the MCP Inspector, a developer tool designed specifically for testing and debugging MCP servers.

To use MCP Inspector with Rails MCP Server:

```
# Install and run MCP Inspector with your Rails MCP Server
npm -g install @modelcontextprotocol/inspector

npx @modelcontextprotocol/inspector /path/to/rails-mcp-server
```

This will:

1. Start your Rails MCP Server in HTTP mode
1. Launch the MCP Inspector UI in your browser (default port: 6274)
1. Set up an MCP Proxy server (default port: 6277)

In the MCP Inspector UI, you can:

- See all available tools
- Execute tool calls interactively
- View request and response details
- Debug issues in real-time

The Inspector UI provides an intuitive interface to interact with your MCP server, making it easy to test and debug your Rails MCP Server implementation.

## License

This Rails MCP server is released under the MIT License, a permissive open-source license that allows for free use, modification, distribution, and private use.

Copyright (c) 2025 Mario Alberto Chávez Cárdenas

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

## Contributing

Bug reports and pull requests are welcome on GitHub at <https://github.com/maquina-app/rails-mcp-server>.
