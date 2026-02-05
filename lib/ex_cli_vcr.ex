defmodule ExCliVcr do
  @moduledoc """
  Record and replay System.cmd and Port calls for testing.

  ExCliVcr intercepts calls to `System.cmd/3` and either records them to a
  cassette file or replays previously recorded responses.

  ## Usage

  In your test:

      use ExCliVcr

      test "runs a command" do
        use_cmd_cassette "my_command" do
          # System.cmd is automatically mocked
          {output, 0} = System.cmd("echo", ["hello"])
          assert output == "hello\\n"
        end
      end

  ## Port Recording

  For Port operations, you must use the ExCliVcr wrapper functions because
  `Port.open/2` compiles to a BIF that cannot be mocked at runtime:

      test "uses a port" do
        use_cmd_cassette "my_port" do
          # Must use ExCliVcr.port_open instead of Port.open
          port = ExCliVcr.port_open({:spawn, "cat"}, [:binary, :exit_status])

          # Use ExCliVcr wrappers for port operations
          ExCliVcr.port_command(port, "hello\\n")
          receive do
            {^port, {:data, data}} -> assert data == "hello\\n"
          end

          ExCliVcr.port_close(port)
        end
      end

  ## Configuration

  Configure ExCliVcr in your `config/test.exs`:

      config :ex_cli_vcr,
        cassette_dir: "test/fixtures/cassettes"

  ## Default Behavior

  By default, the first time a cassette is used, commands are recorded. On
  subsequent runs, recorded responses are replayed and any unrecognized
  command will raise an error.

  ## Record Modes

  - `:new` - Always record, overwriting existing cassettes
  - `:none` - Never record, only replay (raises if cassette missing)
  - `:all` - Record all calls even if cassette exists
  """

  alias ExCliVcr.{Cassette, Recorder}

  defmacro __using__(_opts) do
    quote do
      import ExCliVcr, only: [use_cmd_cassette: 2, use_cmd_cassette: 3]
    end
  end

  @doc """
  Execute a block of code with command recording/playback enabled.

  ## Options

  - `:record` - Override the record mode for this cassette
  - `:match_requests_on` - List of fields to match on (default: `[:command, :args]`)

  ## Examples

      use_cmd_cassette "list_files" do
        ExCliVcr.cmd("ls", ["-la"])
      end

      use_cmd_cassette "list_files", record: :new do
        ExCliVcr.cmd("ls", ["-la"])
      end
  """
  defmacro use_cmd_cassette(name, opts \\ [], do: block) do
    quote do
      cassette_name = unquote(name)
      opts = unquote(opts)

      ExCliVcr.start_cassette(cassette_name, opts)

      try do
        unquote(block)
      after
        ExCliVcr.stop_cassette()
      end
    end
  end

  @doc false
  def start_cassette(name, opts \\ []) do
    record_mode = Keyword.get(opts, :record, default_record_mode())
    match_on = Keyword.get(opts, :match_requests_on, [:command, :args])

    cassette_path = Cassette.path_for(name)
    cassette_existed = File.exists?(cassette_path)
    existing_recordings = Cassette.load(cassette_path)

    Recorder.start(
      cassette_path: cassette_path,
      record_mode: record_mode,
      match_on: match_on,
      recordings: existing_recordings,
      cassette_existed: cassette_existed
    )
  end

  @doc false
  def stop_cassette do
    Recorder.stop()
  end

  @doc """
  Execute a command, recording or replaying as appropriate.

  This is a drop-in replacement for `System.cmd/3` that integrates with
  ExCliVcr's recording and playback system.

  When called inside a `use_cassette` block, it will either:
  - Record the command output if no recording exists
  - Replay a previously recorded response

  When called outside a `use_cassette` block, it passes through to `System.cmd/3`.

  ## Examples

      use_cmd_cassette "my_test" do
        {output, exit_code} = ExCliVcr.cmd("echo", ["hello"], [])
      end
  """
  def cmd(command, args, opts \\ []) do
    case Recorder.execute(command, args, opts) do
      {:error, error} -> raise error
      result -> result
    end
  end

  @doc """
  Execute a command, recording or replaying as appropriate.

  Alias for `cmd/3`.
  """
  def execute_cmd(command, args, opts \\ []) do
    cmd(command, args, opts)
  end

  @doc """
  Open a port, recording or replaying as appropriate.

  Use this instead of `Port.open/2` within a `use_cmd_cassette` block.
  `Port.open/2` cannot be automatically mocked because it compiles to a BIF.

  When called inside a `use_cmd_cassette` block, it will either:
  - Record the port messages if no recording exists
  - Replay previously recorded messages

  When called outside a `use_cmd_cassette` block, it passes through to `Port.open/2`.

  ## Examples

      use_cmd_cassette "my_test" do
        port = ExCliVcr.port_open({:spawn, "echo hello"}, [:binary, :exit_status])
        receive do
          {^port, {:data, data}} -> data
        end
      end
  """
  def port_open(open_args, opts) do
    case GenServer.call(Recorder, {:port_open, open_args, opts}, :infinity) do
      {:ok, port} -> port
      {:error, error} -> raise error
    end
  end

  @doc """
  Send a command to a port.

  Use this instead of Port.command/2 when working with recorded ports.
  """
  def port_command(port, data, _opts \\ []) do
    if is_pid(port) do
      # This is our proxy port
      GenServer.call(Recorder, {:port_command, port, data}, :infinity)
      true
    else
      # Real port, pass through
      Port.command(port, data)
    end
  end

  @doc """
  Close a port.

  Use this instead of Port.close/1 when working with recorded ports.
  """
  def port_close(port) do
    if is_pid(port) do
      # This is our proxy port
      GenServer.call(Recorder, {:port_close, port}, :infinity)
      true
    else
      # Real port, pass through
      Port.close(port)
    end
  end

  @doc """
  Get the configured cassette directory.
  """
  def cassette_dir do
    Application.get_env(:ex_cli_vcr, :cassette_dir, "test/fixtures/cassettes")
  end

  @doc """
  Get the default record mode.
  """
  def default_record_mode do
    Application.get_env(:ex_cli_vcr, :record_mode, nil)
  end
end
