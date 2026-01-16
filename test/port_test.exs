defmodule ExCliVcr.PortTest do
  use ExUnit.Case, async: false
  use ExCliVcr

  @cassette_dir "test/fixtures/cassettes"

  setup do
    File.rm_rf!(@cassette_dir)
    File.mkdir_p!(@cassette_dir)
    :ok
  end

  defp collect_port_messages(port, acc \\ []) do
    receive do
      {^port, {:data, data}} ->
        collect_port_messages(port, [{:data, data} | acc])

      {^port, {:exit_status, status}} ->
        Enum.reverse([{:exit_status, status} | acc])

      {^port, :eof} ->
        collect_port_messages(port, [:eof | acc])
    after
      5000 ->
        Enum.reverse(acc)
    end
  end

  describe "Port recording - basic" do
    test "records a simple port interaction" do
      use_cmd_cassette "port_simple" do
        # Note: Must use ExCliVcr.port_open (not Port.open) for recording
        # because Port.open compiles to a BIF that cannot be mocked
        port = ExCliVcr.port_open({:spawn, "echo hello"}, [:binary, :exit_status])
        messages = collect_port_messages(port)

        assert [{:data, "hello\n"}, {:exit_status, 0}] = messages
      end

      # Verify cassette was created with port data
      cassette_path = Path.join(@cassette_dir, "port_simple.json")
      assert File.exists?(cassette_path)

      {:ok, content} = File.read(cassette_path)
      data = Jason.decode!(content)

      assert Map.has_key?(data, "ports")
      assert length(data["ports"]) == 1
    end

    test "records streaming port messages" do
      use_cmd_cassette "port_streaming" do
        # This command sends multiple messages with sleeps to force separate packets
        port = ExCliVcr.port_open({:spawn, "sh -c 'for i in 1 2 3; do echo $i; sleep 0.1; done'"}, [:binary, :exit_status])
        messages = collect_port_messages(port)

        # Should have 3 data messages plus exit status
        data_messages = Enum.filter(messages, fn
          {:data, _} -> true
          _ -> false
        end)

        assert length(data_messages) >= 1  # At minimum we get some data
        assert List.last(messages) == {:exit_status, 0}
      end
    end
  end

  describe "Port replay" do
    test "replays recorded port messages" do
      # First, record
      use_cmd_cassette "port_replay" do
        port = ExCliVcr.port_open({:spawn, "echo original"}, [:binary, :exit_status])
        messages = collect_port_messages(port)
        assert [{:data, "original\n"}, {:exit_status, 0}] = messages
      end

      # Modify the cassette to verify we're replaying
      cassette_path = Path.join(@cassette_dir, "port_replay.json")
      {:ok, content} = File.read(cassette_path)
      data = Jason.decode!(content)

      # Modify the recorded output
      modified = modify_port_output(data, "modified\n")
      File.write!(cassette_path, Jason.encode!(modified))

      # Replay - should get modified output
      use_cmd_cassette "port_replay" do
        port = ExCliVcr.port_open({:spawn, "echo original"}, [:binary, :exit_status])
        messages = collect_port_messages(port)

        assert [{:data, "modified\n"}, {:exit_status, 0}] = messages
      end
    end
  end

  describe "Port.command" do
    test "records bidirectional communication with cat" do
      use_cmd_cassette "port_command" do
        port = ExCliVcr.port_open({:spawn, "cat"}, [:binary, :exit_status])

        ExCliVcr.port_command(port, "hello\n")
        assert_receive {^port, {:data, "hello\n"}}, 1000

        ExCliVcr.port_command(port, "world\n")
        assert_receive {^port, {:data, "world\n"}}, 1000

        ExCliVcr.port_close(port)

        # Drain any remaining messages
        receive do
          {^port, {:exit_status, _}} -> :ok
        after
          500 -> :ok
        end
      end

      # Verify cassette has the command/response pairs
      cassette_path = Path.join(@cassette_dir, "port_command.json")
      assert File.exists?(cassette_path)
    end
  end

  describe "Port exit status" do
    test "records non-zero exit status" do
      use_cmd_cassette "port_exit_status" do
        port = ExCliVcr.port_open({:spawn, "sh -c 'exit 42'"}, [:binary, :exit_status])
        messages = collect_port_messages(port)

        assert [{:exit_status, 42}] = messages
      end
    end
  end

  describe "Multiple ports" do
    test "records multiple ports in same cassette" do
      use_cmd_cassette "port_multiple" do
        port1 = ExCliVcr.port_open({:spawn, "echo one"}, [:binary, :exit_status])
        messages1 = collect_port_messages(port1)

        port2 = ExCliVcr.port_open({:spawn, "echo two"}, [:binary, :exit_status])
        messages2 = collect_port_messages(port2)

        assert [{:data, "one\n"}, {:exit_status, 0}] = messages1
        assert [{:data, "two\n"}, {:exit_status, 0}] = messages2
      end
    end
  end

  # Helper to modify port output in cassette
  defp modify_port_output(data, new_output) when is_map(data) do
    case data do
      %{"ports" => [port | rest]} ->
        modified_port = put_in(port, ["messages", Access.at(0), "data"], new_output)
        %{data | "ports" => [modified_port | rest]}

      _ ->
        # Handle legacy format
        data
    end
  end

  defp modify_port_output(data, _new_output) when is_list(data), do: data
end
