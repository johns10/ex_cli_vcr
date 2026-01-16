defmodule ExCliVcr.PortProxy do
  @moduledoc """
  Handles Port recording and replay.

  During recording: Creates a real port and proxies messages, logging them.
  During replay: Spawns a fake process that sends recorded messages.
  """

  use GenServer

  defstruct [
    :owner_pid,
    :real_port,
    :open_args,
    :opts,
    :recording,
    messages: [],
    replaying: false
  ]

  # Client API

  @doc """
  Start a port proxy for recording.
  Opens the real port and intercepts messages.
  """
  def start_recording(open_args, opts, owner_pid) do
    GenServer.start(__MODULE__, {:record, open_args, opts, owner_pid})
  end

  @doc """
  Start a port proxy for replay.
  Sends recorded messages to the owner.
  """
  def start_replay(recording, owner_pid) do
    GenServer.start(__MODULE__, {:replay, recording, owner_pid})
  end

  @doc """
  Get the collected messages from a recording proxy.
  """
  def get_messages(proxy) do
    GenServer.call(proxy, :get_messages)
  end

  @doc """
  Forward a Port.command to the real port (during recording).
  """
  def command(proxy, data) do
    GenServer.call(proxy, {:command, data})
  end

  @doc """
  Close the port proxy.
  """
  def close(proxy) do
    GenServer.call(proxy, :close)
  end

  # Server callbacks

  @impl true
  def init({:record, open_args, opts, owner_pid}) do
    # Open the real port
    real_port = open_real_port(open_args, opts)

    state = %__MODULE__{
      owner_pid: owner_pid,
      real_port: real_port,
      open_args: open_args,
      opts: opts,
      messages: [],
      replaying: false
    }

    {:ok, state}
  end

  def init({:replay, recording, owner_pid}) do
    state = %__MODULE__{
      owner_pid: owner_pid,
      recording: recording,
      replaying: true,
      messages: []
    }

    # Schedule message delivery
    send(self(), :deliver_messages)

    {:ok, state}
  end

  @impl true
  def handle_call(:get_messages, _from, state) do
    {:reply, Enum.reverse(state.messages), state}
  end

  @impl true
  def handle_call({:command, data}, _from, %{replaying: false} = state) do
    # Record the outgoing command
    message = %{direction: :out, type: :command, data: data}
    new_state = %{state | messages: [message | state.messages]}

    # Forward to real port
    Port.command(state.real_port, data)

    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:command, _data}, _from, %{replaying: true} = state) do
    # During replay, commands are no-ops (data already recorded)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:close, _from, %{replaying: false} = state) do
    if state.real_port do
      Port.close(state.real_port)
    end
    {:stop, :normal, :ok, state}
  end

  @impl true
  def handle_call(:close, _from, %{replaying: true} = state) do
    {:stop, :normal, :ok, state}
  end

  @impl true
  def handle_info({port, {:data, data}}, %{real_port: port} = state) do
    # Record incoming data and forward to owner
    message = %{direction: :in, type: :data, data: data}
    new_state = %{state | messages: [message | state.messages]}

    # Forward to owner, using self() as the "port" reference
    send(state.owner_pid, {self(), {:data, data}})

    {:noreply, new_state}
  end

  @impl true
  def handle_info({port, {:exit_status, status}}, %{real_port: port} = state) do
    # Record exit status and forward to owner
    message = %{direction: :in, type: :exit_status, data: status}
    new_state = %{state | messages: [message | state.messages]}

    send(state.owner_pid, {self(), {:exit_status, status}})

    {:noreply, new_state}
  end

  @impl true
  def handle_info({port, :eof}, %{real_port: port} = state) do
    message = %{direction: :in, type: :eof, data: nil}
    new_state = %{state | messages: [message | state.messages]}

    send(state.owner_pid, {self(), :eof})

    {:noreply, new_state}
  end

  @impl true
  def handle_info(:deliver_messages, %{replaying: true} = state) do
    # Deliver recorded messages to owner
    messages = state.recording.messages || []

    Enum.each(messages, fn msg ->
      case msg do
        %{direction: :in, type: :data, data: data} ->
          send(state.owner_pid, {self(), {:data, data}})

        %{direction: :in, type: :exit_status, data: status} ->
          send(state.owner_pid, {self(), {:exit_status, status}})

        %{direction: :in, type: :eof} ->
          send(state.owner_pid, {self(), :eof})

        _ ->
          :ok
      end
    end)

    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # Helpers

  defp open_real_port(open_args, opts) do
    # Open the real port directly (no mocking of Port module)
    Port.open(open_args, opts)
  end
end
