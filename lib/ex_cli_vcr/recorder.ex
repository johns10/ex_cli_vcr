defmodule ExCliVcr.Recorder do
  @moduledoc """
  GenServer that manages recording and playback of System.cmd and Port calls.

  The Recorder maintains state about the current cassette and handles
  the logic for deciding whether to record or replay commands and ports.
  """

  use GenServer

  alias ExCliVcr.{Cassette, PortProxy}

  defstruct [
    :cassette_path,
    :record_mode,
    :match_on,
    :sequential,
    # Commands
    command_recordings: [],
    new_command_recordings: [],
    # Ports
    port_recordings: [],
    new_port_recordings: [],
    # Map of proxy pid -> recording info for active ports
    active_ports: %{},
    active: false,
    # Whether the cassette file existed when we started
    cassette_existed: false,
    # Paths to ignore, e.g. [[:opts, :cd]] — masked with "*" in recordings
    ignore: []
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
    existing = Keyword.get(opts, :recordings, %{commands: [], ports: []})

    # For :new mode, ignore existing recordings - start fresh
    {command_recordings, port_recordings} =
      if record_mode == :new do
        {[], []}
      else
        {Map.get(existing, :commands, []), Map.get(existing, :ports, [])}
      end

    state = %__MODULE__{
      cassette_path: Keyword.fetch!(opts, :cassette_path),
      record_mode: record_mode,
      match_on: Keyword.get(opts, :match_on, [:command, :args]),
      sequential: Keyword.get(opts, :sequential, false),
      command_recordings: command_recordings,
      new_command_recordings: [],
      port_recordings: port_recordings,
      new_port_recordings: [],
      active_ports: %{},
      active: true,
      cassette_existed: Keyword.get(opts, :cassette_existed, false),
      ignore: Keyword.get(opts, :ignore, [])
    }

    # Install mocks for System.cmd and Port
    install_mock()

    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:stop, _from, state) do
    # Collect messages from any still-active recording ports
    final_port_recordings =
      state.active_ports
      |> Enum.reduce(state.new_port_recordings, fn {proxy_pid, port_info}, acc ->
        messages = PortProxy.get_messages(proxy_pid)

        recording = %{
          open_args: port_info.open_args,
          opts: port_info.opts,
          messages: messages,
          recorded_at: DateTime.utc_now() |> DateTime.to_iso8601()
        }

        [recording | acc]
      end)

    # Uninstall the mock
    uninstall_mock()

    # Save if we have any new recordings
    has_new_commands = length(state.new_command_recordings) > 0
    has_new_ports = length(final_port_recordings) > 0

    if state.active and (has_new_commands or has_new_ports) do
      all_recordings = %{
        commands: state.command_recordings ++ Enum.reverse(state.new_command_recordings),
        ports: state.port_recordings ++ Enum.reverse(final_port_recordings)
      }

      Cassette.save(state.cassette_path, all_recordings)
    end

    {:reply, :ok, %__MODULE__{}}
  end

  @impl true
  def handle_call({:execute, command, args, opts}, _from, state) do
    if state.active do
      case do_execute_cmd(command, args, opts, state) do
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
  def handle_call({:port_open, open_args, opts}, {owner_pid, _}, state) do
    if state.active do
      case do_port_open(open_args, opts, owner_pid, state) do
        {:ok, proxy_pid, new_state} ->
          {:reply, {:ok, proxy_pid}, new_state}

        {:error, error} ->
          {:reply, {:error, error}, state}
      end
    else
      # Not active, pass through to real Port.open
      port = real_port_open(open_args, opts)
      {:reply, {:ok, port}, state}
    end
  end

  @impl true
  def handle_call({:port_command, port, data}, _from, state) do
    if Map.has_key?(state.active_ports, port) do
      PortProxy.command(port, data)
      {:reply, :ok, state}
    else
      # Not our port, pass through
      Port.command(port, data)
      {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call({:port_close, port}, _from, state) do
    if Map.has_key?(state.active_ports, port) do
      # Collect messages and finalize the recording
      port_info = state.active_ports[port]
      messages = PortProxy.get_messages(port)
      PortProxy.close(port)

      recording = %{
        open_args: port_info.open_args,
        opts: port_info.opts,
        messages: messages,
        recorded_at: DateTime.utc_now() |> DateTime.to_iso8601()
      }

      new_state = %{
        state
        | active_ports: Map.delete(state.active_ports, port),
          new_port_recordings: [recording | state.new_port_recordings]
      }

      {:reply, :ok, new_state}
    else
      {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call(:active?, _from, state) do
    {:reply, state.active, state}
  end

  # Private functions - Commands

  defp do_execute_cmd(command, args, opts, state) do
    case state.record_mode do
      :none ->
        replay_cmd_or_error(command, args, opts, state)

      :new ->
        record_and_execute_cmd(command, args, opts, state)

      :all ->
        record_and_execute_cmd(command, args, opts, state)

      _ ->
        if state.cassette_existed do
          replay_cmd_or_error(command, args, opts, state)
        else
          record_and_execute_cmd(command, args, opts, state)
        end
    end
  end

  defp replay_cmd_or_error(command, args, opts, state) do
    case find_cmd_recording(command, args, opts, state) do
      nil ->
        {:error,
         %ExCliVcr.CassetteNotFoundError{
           message: "No recording found for: #{command} #{Enum.join(args, " ")}"
         }}

      recording ->
        state = if state.sequential, do: consume(state, recording), else: state
        {:ok, {recording.output, recording.exit_code}, state}
    end
  end

  # Under `sequential: true` a replayed recording is spent, so the next
  # identical command gets the next recording rather than the same one
  # forever.
  #
  # Sequences repeat commands whose answers differ, and that is normal rather
  # than exotic: `git rev-parse HEAD` fails before the first commit and
  # succeeds after it, so replaying the first match every time reported "no
  # HEAD" to a caller that had just made one. The failure surfaces as the
  # command being wrong rather than as the cassette being consumed wrongly.
  #
  # Off by default: replaying one recording for many identical calls is the
  # right behaviour when a command is idempotent, and turning that off
  # everywhere would break cassettes that rely on it.
  #
  # Recordings that were never matched are left alone, so a cassette may still
  # carry commands a given run does not reach.
  defp consume(state, recording) do
    case Enum.split_while(state.command_recordings, &(&1 != recording)) do
      {_before, []} ->
        remaining = Enum.reject(state.new_command_recordings, &(&1 == recording))
        %{state | new_command_recordings: remaining}

      {before, [_spent | rest]} ->
        %{state | command_recordings: before ++ rest}
    end
  end

  defp record_and_execute_cmd(command, args, opts, state) do
    {output, exit_code} = real_cmd(command, args, opts)

    masked_opts = mask_ignored_opts(opts, state.ignore)

    recording = %{
      command: command,
      args: args,
      opts: masked_opts,
      output: output,
      exit_code: exit_code,
      recorded_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    new_state = %{state | new_command_recordings: [recording | state.new_command_recordings]}
    {:ok, {output, exit_code}, new_state}
  end

  defp find_cmd_recording(command, args, opts, state) do
    all_recordings = state.command_recordings ++ Enum.reverse(state.new_command_recordings)

    Enum.find(all_recordings, fn recording ->
      cmd_matches?(recording, command, args, opts, state.match_on)
    end)
  end

  defp cmd_matches?(recording, command, args, opts, match_on) do
    Enum.all?(match_on, fn field ->
      case field do
        :command -> recording.command == command
        :args -> args_match?(recording.args, args)
        :cd ->
          recorded = Keyword.get(recording.opts || [], :cd)
          recorded == "*" || recorded == Keyword.get(opts, :cd)
        :env ->
          recorded = Keyword.get(recording.opts || [], :env)
          recorded == "*" || recorded == Keyword.get(opts, :env)
        _ -> true
      end
    end)
  end

  # `cd` and `env` have honoured a recorded "*" since the ignore option
  # landed; `args` never did, and it was the one that mattered. A path that
  # travels as an argument — `mix spex --jsonl=/abs/path` — was compared by
  # exact equality, which pins the cassette to the checkout that recorded it.
  # The same suite then passes on one machine and fails on every other, with
  # "No recording found" pointing at the command rather than at the path
  # inside it.
  #
  # A recorded arg is a glob when it contains "*", so `--jsonl=*` still
  # requires the flag and only forgives the path. Masking the whole argument
  # would match any `mix spex` invocation, which is looser than anyone wants.
  defp args_match?(recorded, actual)
       when is_list(recorded) and is_list(actual) and length(recorded) == length(actual) do
    recorded
    |> Enum.zip(actual)
    |> Enum.all?(fn {r, a} -> arg_matches?(r, a) end)
  end

  defp args_match?(recorded, actual), do: recorded == actual

  defp arg_matches?(recorded, actual) when is_binary(recorded) and is_binary(actual) do
    if String.contains?(recorded, "*") do
      pattern =
        recorded
        |> String.split("*")
        |> Enum.map_join(".*", &Regex.escape/1)

      Regex.match?(Regex.compile!("\\A" <> pattern <> "\\z", "s"), actual)
    else
      recorded == actual
    end
  end

  defp arg_matches?(recorded, actual), do: recorded == actual

  defp mask_ignored_opts(opts, ignore_paths) do
    Enum.reduce(ignore_paths, opts, fn
      [:opts, key], acc ->
        if Keyword.has_key?(acc, key), do: Keyword.put(acc, key, "*"), else: acc
      _, acc ->
        acc
    end)
  end

  # Private functions - Ports

  defp do_port_open(open_args, opts, owner_pid, state) do
    case state.record_mode do
      :none ->
        replay_port_or_error(open_args, opts, owner_pid, state)

      :new ->
        record_port_open(open_args, opts, owner_pid, state)

      :all ->
        record_port_open(open_args, opts, owner_pid, state)

      _ ->
        if state.cassette_existed do
          replay_port_or_error(open_args, opts, owner_pid, state)
        else
          record_port_open(open_args, opts, owner_pid, state)
        end
    end
  end

  defp replay_port_or_error(open_args, opts, owner_pid, state) do
    case find_port_recording(open_args, opts, state) do
      nil ->
        {:error,
         %ExCliVcr.CassetteNotFoundError{
           message: "No port recording found for: #{inspect(open_args)}"
         }}

      recording ->
        replay_port(recording, owner_pid, state)
    end
  end

  defp record_port_open(open_args, opts, owner_pid, state) do
    {:ok, proxy_pid} = PortProxy.start_recording(open_args, opts, owner_pid)

    port_info = %{open_args: serialize_open_args(open_args), opts: opts}
    new_state = %{state | active_ports: Map.put(state.active_ports, proxy_pid, port_info)}

    {:ok, proxy_pid, new_state}
  end

  defp replay_port(recording, owner_pid, state) do
    {:ok, proxy_pid} = PortProxy.start_replay(recording, owner_pid)
    {:ok, proxy_pid, state}
  end

  defp find_port_recording(open_args, _opts, state) do
    all_recordings = state.port_recordings ++ Enum.reverse(state.new_port_recordings)
    serialized = serialize_open_args(open_args)

    Enum.find(all_recordings, fn recording ->
      recording.open_args == serialized
    end)
  end

  defp serialize_open_args(open_args) do
    inspect(open_args)
  end

  defp real_cmd(command, args, opts) do
    # Filter opts to only include valid System.cmd options
    valid_opts =
      opts
      |> Keyword.take([:cd, :env, :arg0, :stderr_to_stdout, :into, :parallelism])

    # Call the original System.cmd implementation directly
    orig_mod = :meck_util.original_name(System)
    apply(orig_mod, :cmd, [command, args, valid_opts])
  end

  defp real_port_open(open_args, opts) do
    # Call Port.open directly (Port is not mocked)
    Port.open(open_args, opts)
  end

  defp install_mock do
    # Unload any existing mocks first
    uninstall_mock()

    # Create a mock for System module
    :meck.new(System, [:passthrough, :unstick])

    # Mock cmd/3 to go through our recorder
    :meck.expect(System, :cmd, fn command, args, opts ->
      ExCliVcr.cmd(command, args, opts)
    end)

    # Mock cmd/2 (no opts) to go through our recorder
    :meck.expect(System, :cmd, fn command, args ->
      ExCliVcr.cmd(command, args, [])
    end)

    # Note: Port.open cannot be mocked because it compiles to a BIF.
    # Users must call ExCliVcr.port_open/port_command/port_close explicitly
    # for port recording/playback.

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
