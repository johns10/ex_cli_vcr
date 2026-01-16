defmodule ExCliVcr do
  @moduledoc """
  Record and replay System.cmd calls for testing.

  ExCliVcr intercepts calls to `System.cmd/3` and either records them to a
  cassette file or replays previously recorded responses.

  ## Usage

  In your test:

      use ExCliVcr

      test "runs a command" do
        use_cmd_cassette "my_command" do
          {output, 0} = ExCliVcr.cmd("echo", ["hello"])
          assert output == "hello\\n"
        end
      end

  ## Configuration

  Configure ExCliVcr in your `config/test.exs`:

      config :cli_vcr,
        cassette_dir: "test/fixtures/cassettes",
        record_mode: :once

  ## Record Modes

  - `:once` - Record if cassette doesn't exist, replay if it does (default)
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
    existing_recordings = Cassette.load(cassette_path)

    Recorder.start(
      cassette_path: cassette_path,
      record_mode: record_mode,
      match_on: match_on,
      recordings: existing_recordings
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
  Get the configured cassette directory.
  """
  def cassette_dir do
    Application.get_env(:cli_vcr, :cassette_dir, "test/fixtures/cassettes")
  end

  @doc """
  Get the default record mode.
  """
  def default_record_mode do
    Application.get_env(:cli_vcr, :record_mode, :once)
  end
end
