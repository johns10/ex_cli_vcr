defmodule ExCliVcr.Cassette do
  @moduledoc """
  Handles reading and writing cassette files.

  Cassettes are JSON files that store recorded command and port executions.

  ## Format

  Cassettes use a structured format:

      {
        "commands": [...],
        "ports": [...]
      }
  """

  @doc """
  Get the full path for a cassette name.
  """
  def path_for(name) do
    dir = ExCliVcr.cassette_dir()
    Path.join(dir, "#{name}.json")
  end

  @doc """
  Load recordings from a cassette file.

  Returns a map with :commands and :ports keys.
  """
  def load(path) do
    case File.read(path) do
      {:ok, content} ->
        content
        |> Jason.decode!()
        |> decode_cassette()

      {:error, :enoent} ->
        %{commands: [], ports: []}

      {:error, reason} ->
        raise "Failed to load cassette #{path}: #{inspect(reason)}"
    end
  end

  @doc """
  Save recordings to a cassette file.
  """
  def save(path, recordings) do
    dir = Path.dirname(path)
    File.mkdir_p!(dir)

    content =
      recordings
      |> encode_cassette()
      |> Jason.encode!(pretty: true)

    File.write!(path, content)
  end

  # Decode cassette - handle both new format and legacy format
  defp decode_cassette(%{"commands" => commands, "ports" => ports}) do
    %{
      commands: Enum.map(commands, &decode_command/1),
      ports: Enum.map(ports, &decode_port/1)
    }
  end

  # Legacy format - just a list of commands
  defp decode_cassette(data) when is_list(data) do
    %{
      commands: Enum.map(data, &decode_command/1),
      ports: []
    }
  end

  defp decode_cassette(_), do: %{commands: [], ports: []}

  defp encode_cassette(%{commands: commands, ports: ports}) do
    %{
      "commands" => Enum.map(commands, &encode_command/1),
      "ports" => Enum.map(ports, &encode_port/1)
    }
  end

  # Also handle legacy format for backwards compatibility
  defp encode_cassette(recordings) when is_list(recordings) do
    %{
      "commands" => Enum.map(recordings, &encode_command/1),
      "ports" => []
    }
  end

  # Command encoding/decoding

  defp decode_command(data) do
    %{
      type: :command,
      command: data["command"],
      args: data["args"],
      opts: decode_opts(data["opts"]),
      output: data["output"],
      exit_code: data["exit_code"],
      recorded_at: data["recorded_at"]
    }
  end

  defp encode_command(recording) do
    %{
      "command" => recording.command,
      "args" => recording.args,
      "opts" => encode_opts(recording.opts),
      "output" => recording.output,
      "exit_code" => recording.exit_code,
      "recorded_at" => recording.recorded_at || DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  # Port encoding/decoding

  defp decode_port(data) do
    %{
      type: :port,
      open_args: data["open_args"],
      opts: data["opts"] || [],
      messages: Enum.map(data["messages"] || [], &decode_port_message/1),
      recorded_at: data["recorded_at"]
    }
  end

  defp encode_port(recording) do
    %{
      "open_args" => recording.open_args,
      "opts" => recording.opts,
      "messages" => Enum.map(recording.messages, &encode_port_message/1),
      "recorded_at" => recording.recorded_at || DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  defp decode_port_message(%{"direction" => dir, "type" => type} = msg) do
    %{
      direction: String.to_atom(dir),
      type: String.to_atom(type),
      data: msg["data"]
    }
  end

  defp encode_port_message(msg) do
    %{
      "direction" => to_string(msg.direction),
      "type" => to_string(msg.type),
      "data" => msg.data
    }
  end

  defp decode_opts(nil), do: []

  defp decode_opts(opts) when is_map(opts) do
    opts
    |> Enum.reduce([], fn {k, v}, acc ->
      case k do
        "cd" -> [{:cd, v} | acc]
        "stderr_to_stdout" -> [{:stderr_to_stdout, v} | acc]
        "env" -> [{:env, decode_env(v)} | acc]
        _ -> acc
      end
    end)
  rescue
    ArgumentError -> []
  end

  defp decode_opts(opts) when is_list(opts), do: opts

  defp decode_env(nil), do: []
  defp decode_env(env) when is_map(env) do
    Enum.map(env, fn {k, v} -> {k, v} end)
  end
  defp decode_env(env) when is_list(env), do: env

  defp encode_opts(opts) when is_list(opts) do
    opts
    |> Enum.reduce(%{}, fn {k, v}, acc ->
      case k do
        :cd -> Map.put(acc, "cd", v)
        :stderr_to_stdout -> Map.put(acc, "stderr_to_stdout", v)
        :env -> Map.put(acc, "env", encode_env(v))
        _ -> acc
      end
    end)
  end

  defp encode_opts(_), do: %{}

  defp encode_env(env) when is_list(env) do
    Enum.into(env, %{}, fn {k, v} -> {k, v} end)
  end
  defp encode_env(_), do: %{}
end
