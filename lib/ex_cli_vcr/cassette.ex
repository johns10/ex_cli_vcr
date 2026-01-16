defmodule ExCliVcr.Cassette do
  @moduledoc """
  Handles reading and writing cassette files.

  Cassettes are JSON files that store recorded command executions.
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

  Returns an empty list if the file doesn't exist.
  """
  def load(path) do
    case File.read(path) do
      {:ok, content} ->
        content
        |> Jason.decode!()
        |> Enum.map(&decode_recording/1)

      {:error, :enoent} ->
        []

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
      |> Enum.map(&encode_recording/1)
      |> Jason.encode!(pretty: true)

    File.write!(path, content)
  end

  defp decode_recording(data) do
    %{
      command: data["command"],
      args: data["args"],
      opts: decode_opts(data["opts"]),
      output: data["output"],
      exit_code: data["exit_code"],
      recorded_at: data["recorded_at"]
    }
  end

  defp encode_recording(recording) do
    %{
      "command" => recording.command,
      "args" => recording.args,
      "opts" => encode_opts(recording.opts),
      "output" => recording.output,
      "exit_code" => recording.exit_code,
      "recorded_at" => recording.recorded_at || DateTime.utc_now() |> DateTime.to_iso8601()
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
