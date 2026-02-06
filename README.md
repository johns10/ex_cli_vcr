# ExCliVcr

Record and replay `System.cmd` and `Port` calls for testing, inspired by [ExVCR](https://github.com/parroty/exvcr).

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
  use ExUnit.Case, async: false
  use ExCliVcr

  test "runs a command" do
    use_cmd_cassette "my_command" do
      # First run: executes the real command and records the output
      # Subsequent runs: replays the recorded output
      {output, exit_code} = System.cmd("echo", ["hello"])
      assert output == "hello\n"
      assert exit_code == 0
    end
  end
end
```

**Note:** Tests using ExCliVcr should use `async: false` since the library mocks global state.

## Usage

### Basic Recording and Playback

Just use `System.cmd/3` as normal within a `use_cmd_cassette` block - ExCliVcr automatically intercepts the calls:

```elixir
use_cmd_cassette "list_files" do
  {output, 0} = System.cmd("ls", ["-la"])
  # Process output...
end
```

The first time this runs, it executes the real command and saves the output to `test/fixtures/cassettes/list_files.json`. On subsequent runs, it replays the recorded output without executing the command.

### Record Modes

By default, the first time a cassette is used, commands are recorded. On subsequent runs, recorded responses are replayed and any unrecognized command will raise an error.

Override this with the `:record` option:

```elixir
# :new - Always record, overwriting existing cassettes
use_cmd_cassette "my_test", record: :new do
  System.cmd("echo", ["test"])
end

# :none - Never record, only replay (raises if cassette missing)
use_cmd_cassette "my_test", record: :none do
  System.cmd("echo", ["test"])
end

# :all - Record all calls even if cassette exists (appends)
use_cmd_cassette "my_test", record: :all do
  System.cmd("echo", ["test"])
end
```

### Command Options

ExCliVcr supports the same options as `System.cmd/3`:

```elixir
use_cmd_cassette "with_options" do
  # Change working directory
  System.cmd("pwd", [], cd: "/tmp")

  # Set environment variables
  System.cmd("sh", ["-c", "echo $MY_VAR"], env: [{"MY_VAR", "value"}])

  # Redirect stderr to stdout
  System.cmd("ls", ["nonexistent"], stderr_to_stdout: true)
end
```

### Request Matching

By default, cassettes match on command and arguments. Customize this with `:match_requests_on`:

```elixir
# Match only on command (ignore arguments)
use_cmd_cassette "my_test", match_requests_on: [:command] do
  System.cmd("date", [])
end

# Match on command, args, and working directory
use_cmd_cassette "my_test", match_requests_on: [:command, :args, :cd] do
  System.cmd("pwd", [], cd: "/tmp")
end
```

### Ignoring Options

Use the `:ignore` option to mask sensitive or variable values in recordings. Ignored fields are stored as `"*"` in the cassette and skipped during matching:

```elixir
# The cd path will be stored as "*" and won't be matched on replay
use_cmd_cassette "my_test", ignore: [[:opts, :cd]] do
  System.cmd("mix", ["credo"], cd: "../some/project", stderr_to_stdout: true)
end
```

### Port Recording

ExCliVcr also supports recording and replaying Port operations. Unlike `System.cmd`, Port operations **require explicit wrapper functions** because `Port.open/2` compiles to a BIF that cannot be intercepted at runtime.

```elixir
use_cmd_cassette "port_test" do
  # Use ExCliVcr.port_open instead of Port.open
  port = ExCliVcr.port_open({:spawn, "cat"}, [:binary, :exit_status])

  # Use ExCliVcr wrappers for port operations
  ExCliVcr.port_command(port, "hello\n")

  # Receive messages as normal - the port reference works the same
  receive do
    {^port, {:data, data}} ->
      assert data == "hello\n"
  end

  ExCliVcr.port_close(port)
end
```

The wrapper functions are:
- `ExCliVcr.port_open/2` - Opens a port (records/replays)
- `ExCliVcr.port_command/2` - Sends data to a port
- `ExCliVcr.port_close/1` - Closes a port

During recording, all messages sent to and received from the port are captured. During replay, the recorded messages are sent to your process on the same schedule.

## Configuration

Configure ExCliVcr in your `config/test.exs`:

```elixir
config :ex_cli_vcr,
  cassette_dir: "test/fixtures/cassettes"  # Where to store cassette files
```

## Cassette Format

Cassettes are stored as JSON files with the following structure:

```json
{
  "commands": [
    {
      "command": "echo",
      "args": ["hello"],
      "opts": {},
      "output": "hello\n",
      "exit_code": 0,
      "recorded_at": "2024-01-15T10:30:00Z"
    }
  ],
  "ports": [
    {
      "open_args": "{:spawn, \"cat\"}",
      "opts": [":binary", ":exit_status"],
      "messages": [
        {"direction": "in", "type": "data", "data": "hello\n"},
        {"direction": "in", "type": "exit_status", "data": 0}
      ],
      "recorded_at": "2024-01-15T10:30:00Z"
    }
  ]
}
```

## License

MIT License
