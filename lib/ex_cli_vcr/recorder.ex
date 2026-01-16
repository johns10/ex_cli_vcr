defmodule ExCliVcr.Recorder do
  @moduledoc """
  GenServer that manages recording and playback of System.cmd calls.

  The Recorder maintains state about the current cassette and handles
  the logic for deciding whether to record or replay commands.
  """

  use GenServer

  alias ExCliVcr.Cassette

  defstruct [
    :cassette_path,
    :record_mode,
    :match_on,
    recordings: [],
    new_recordings: [],
    active: false
  ]

  # Client API

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %__MODULE__{}, name: __MODULE__)
  end

  @doc """
  Start recording/playback for a cassette.
  """
  def start(opts) do
    GenServer.call(__MODULE__, {:start, opts})
  end

  @doc """
  Stop recording and save the cassette.
  """
  def stop do
    GenServer.call(__MODULE__, :stop)
  end

  @doc """
  Execute a command through the recorder.
  """
  def execute(command, args, opts) do
    GenServer.call(__MODULE__, {:execute, command, args, opts}, :infinity)
  end

  @doc """
  Check if recording is currently active.
  """
  def active? do
    GenServer.call(__MODULE__, :active?)
  end

  # Server callbacks

  @impl true
  def init(state) do
    {:ok, state}
  end

  @impl true
  def handle_call({:start, opts}, _from, _state) do
    record_mode = Keyword.fetch!(opts, :record_mode)
    existing_recordings = Keyword.get(opts, :recordings, [])

    # For :new mode, ignore existing recordings - start fresh
    recordings = if record_mode == :new, do: [], else: existing_recordings

    state = %__MODULE__{
      cassette_path: Keyword.fetch!(opts, :cassette_path),
      record_mode: record_mode,
      match_on: Keyword.get(opts, :match_on, [:command, :args]),
      recordings: recordings,
      new_recordings: [],
      active: true
    }

    # Install the mock for System.cmd
    install_mock()

    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:stop, _from, state) do
    # Uninstall the mock
    uninstall_mock()

    if state.active and length(state.new_recordings) > 0 do
      all_recordings = state.recordings ++ Enum.reverse(state.new_recordings)
      Cassette.save(state.cassette_path, all_recordings)
    end

    {:reply, :ok, %__MODULE__{}}
  end

  @impl true
  def handle_call({:execute, command, args, opts}, _from, state) do
    if state.active do
      case do_execute(command, args, opts, state) do
        {:ok, result, new_state} ->
          {:reply, result, new_state}

        {:error, error} ->
          {:reply, {:error, error}, state}
      end
    else
      # Not active, just pass through to real System.cmd
      result = real_cmd(command, args, opts)
      {:reply, result, state}
    end
  end

  @impl true
  def handle_call(:active?, _from, state) do
    {:reply, state.active, state}
  end

  # Private functions

  defp do_execute(command, args, opts, state) do
    case state.record_mode do
      :none ->
        replay_or_error(command, args, opts, state)

      :once ->
        case find_recording(command, args, opts, state) do
          nil ->
            record_and_execute(command, args, opts, state)

          recording ->
            {:ok, {recording.output, recording.exit_code}, state}
        end

      :new ->
        record_and_execute(command, args, opts, state)

      :all ->
        record_and_execute(command, args, opts, state)
    end
  end

  defp replay_or_error(command, args, opts, state) do
    case find_recording(command, args, opts, state) do
      nil ->
        {:error, %ExCliVcr.CassetteNotFoundError{
          message: "No recording found for: #{command} #{Enum.join(args, " ")}"
        }}

      recording ->
        {:ok, {recording.output, recording.exit_code}, state}
    end
  end

  defp record_and_execute(command, args, opts, state) do
    {output, exit_code} = real_cmd(command, args, opts)

    recording = %{
      command: command,
      args: args,
      opts: opts,
      output: output,
      exit_code: exit_code,
      recorded_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    new_state = %{state | new_recordings: [recording | state.new_recordings]}
    {:ok, {output, exit_code}, new_state}
  end

  defp find_recording(command, args, opts, state) do
    all_recordings = state.recordings ++ Enum.reverse(state.new_recordings)

    Enum.find(all_recordings, fn recording ->
      matches?(recording, command, args, opts, state.match_on)
    end)
  end

  defp matches?(recording, command, args, opts, match_on) do
    Enum.all?(match_on, fn field ->
      case field do
        :command -> recording.command == command
        :args -> recording.args == args
        :cd -> Keyword.get(recording.opts || [], :cd) == Keyword.get(opts, :cd)
        :env -> Keyword.get(recording.opts || [], :env) == Keyword.get(opts, :env)
        _ -> true
      end
    end)
  end

  defp real_cmd(command, args, opts) do
    # Filter opts to only include valid System.cmd options
    valid_opts =
      opts
      |> Keyword.take([:cd, :env, :arg0, :stderr_to_stdout, :into, :parallelism])

    # Call the original System.cmd implementation directly via :meck_code_gen.get_orig_mod/1
    # or use the underlying implementation
    orig_mod = :meck_util.original_name(System)
    apply(orig_mod, :cmd, [command, args, valid_opts])
  end

  defp install_mock do
    # Unload any existing mock first
    uninstall_mock()

    # Create a mock for System module, keeping original functions
    # :unstick is needed for OTP modules, :passthrough keeps non-mocked functions working
    :meck.new(System, [:passthrough, :unstick])

    # Mock cmd/3 to go through our recorder
    :meck.expect(System, :cmd, fn command, args, opts ->
      ExCliVcr.cmd(command, args, opts)
    end)

    # Mock cmd/2 (no opts) to go through our recorder
    :meck.expect(System, :cmd, fn command, args ->
      ExCliVcr.cmd(command, args, [])
    end)

    :ok
  end

  defp uninstall_mock do
    :meck.unload(System)
    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end
end
