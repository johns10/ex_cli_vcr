# ExCliVcr

Record and replay `System.cmd` calls for testing, inspired by [ExVCR](https://github.com/parroty/exvcr).

ExCliVcr intercepts calls to command-line programs and either records their output to cassette files or replays previously recorded responses. This is useful for testing code that shells out to external commands without actually running those commands during tests.

## Installation

Add `ex_cli_vcr` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:ex_cli_vcr, "~> 0.1.0", only: :test}
  ]
end
```

## Quick Start

```elixir
defmodule MyTest do
  use ExUnit.Case
  use ExCliVcr

  test "runs a command" do
    use_cmd_cassette "my_command" do
      # First run: executes the real command and records the output
      # Subsequent runs: replays the recorded output
      {output, exit_code} = ExCliVcr.cmd("echo", ["hello"])
      assert output == "hello\n"
      assert exit_code == 0
    end
  end
end
```

## Usage

### Basic Recording and Playback

Use `ExCliVcr.cmd/3` instead of `System.cmd/3` within a `use_cmd_cassette` block:

```elixir
use_cmd_cassette "list_files" do
  {output, 0} = ExCliVcr.cmd("ls", ["-la"])
  # Process output...
end
```

The first time this runs, it executes the real command and saves the output to `test/fixtures/cassettes/list_files.json`. On subsequent runs, it replays the recorded output without executing the command.

### Record Modes

Control how cassettes are recorded with the `:record` option:

```elixir
# :once (default) - Record if cassette doesn't exist, replay if it does
use_cmd_cassette "my_test" do
  ExCliVcr.cmd("echo", ["test"])
end

# :new - Always record, overwriting existing cassettes
use_cmd_cassette "my_test", record: :new do
  ExCliVcr.cmd("echo", ["test"])
end

# :none - Never record, only replay (raises if cassette missing)
use_cmd_cassette "my_test", record: :none do
  ExCliVcr.cmd("echo", ["test"])
end

# :all - Record all calls even if cassette exists (appends)
use_cmd_cassette "my_test", record: :all do
  ExCliVcr.cmd("echo", ["test"])
end
```

### Command Options

ExCliVcr supports the same options as `System.cmd/3`:

```elixir
use_cmd_cassette "with_options" do
  # Change working directory
  ExCliVcr.cmd("pwd", [], cd: "/tmp")

  # Set environment variables
  ExCliVcr.cmd("sh", ["-c", "echo $MY_VAR"], env: [{"MY_VAR", "value"}])

  # Redirect stderr to stdout
  ExCliVcr.cmd("ls", ["nonexistent"], stderr_to_stdout: true)
end
```

### Request Matching

By default, cassettes match on command and arguments. Customize this with `:match_requests_on`:

```elixir
# Match only on command (ignore arguments)
use_cmd_cassette "my_test", match_requests_on: [:command] do
  ExCliVcr.cmd("date", [])
end

# Match on command, args, and working directory
use_cmd_cassette "my_test", match_requests_on: [:command, :args, :cd] do
  ExCliVcr.cmd("pwd", [], cd: "/tmp")
end
```

### Using with Existing Code

If you have existing code that calls `System.cmd`, you can make it testable by using dependency injection:

```elixir
defmodule MyModule do
  def run_command(cmd_fn \\ &System.cmd/3) do
    cmd_fn.("echo", ["hello"], [])
  end
end

# In your test:
use_cmd_cassette "my_test" do
  MyModule.run_command(&ExCliVcr.cmd/3)
end
```

Or use module configuration:

```elixir
# lib/my_module.ex
defmodule MyModule do
  @cmd_module Application.compile_env(:my_app, :cmd_module, System)

  def run_command do
    @cmd_module.cmd("echo", ["hello"], [])
  end
end

# config/test.exs
config :my_app, :cmd_module, ExCliVcr
```

## Configuration

Configure ExCliVcr in your `config/test.exs`:

```elixir
config :ex_cli_vcr,
  cassette_dir: "test/fixtures/cassettes",  # Where to store cassette files
  record_mode: :once                         # Default record mode
```

## Cassette Format

Cassettes are stored as JSON files with the following structure:

```json
[
  {
    "command": "echo",
    "args": ["hello"],
    "opts": {},
    "output": "hello\n",
    "exit_code": 0,
    "recorded_at": "2024-01-15T10:30:00Z"
  }
]
```

## License

MIT License
