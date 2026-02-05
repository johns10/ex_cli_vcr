defmodule ExCliVcrTest do
  # async: false required because ExCliVcr mocks global System.cmd
  use ExUnit.Case, async: false
  use ExCliVcr

  @cassette_dir "test/fixtures/cassettes"

  setup do
    # Clean up cassettes before each test
    File.rm_rf!(@cassette_dir)
    File.mkdir_p!(@cassette_dir)
    :ok
  end

  describe "use_cmd_cassette/2" do
    test "records a new command execution" do
      use_cmd_cassette "echo_test" do
        {output, exit_code} = System.cmd("echo", ["hello"])
        assert output == "hello\n"
        assert exit_code == 0
      end

      # Verify the cassette was created
      cassette_path = Path.join(@cassette_dir, "echo_test.json")
      assert File.exists?(cassette_path)

      {:ok, content} = File.read(cassette_path)
      %{"commands" => [recording], "ports" => []} = Jason.decode!(content)

      assert recording["command"] == "echo"
      assert recording["args"] == ["hello"]
      assert recording["output"] == "hello\n"
      assert recording["exit_code"] == 0
    end

    test "replays a recorded command" do
      # First, record the command
      use_cmd_cassette "replay_test" do
        {output, exit_code} = System.cmd("echo", ["first run"])
        assert output == "first run\n"
        assert exit_code == 0
      end

      # Modify the cassette to verify we're replaying, not re-running
      cassette_path = Path.join(@cassette_dir, "replay_test.json")
      {:ok, content} = File.read(cassette_path)
      %{"commands" => [recording], "ports" => []} = Jason.decode!(content)

      modified_recording = Map.put(recording, "output", "modified output\n")
      File.write!(cassette_path, Jason.encode!(%{"commands" => [modified_recording], "ports" => []}))

      # Now replay - should get the modified output
      use_cmd_cassette "replay_test" do
        {output, _exit_code} = System.cmd("echo", ["first run"])
        assert output == "modified output\n"
      end
    end

    test "records multiple commands in a single cassette" do
      use_cmd_cassette "multiple_commands" do
        {output1, _} = System.cmd("echo", ["one"])
        {output2, _} = System.cmd("echo", ["two"])

        assert output1 == "one\n"
        assert output2 == "two\n"
      end

      cassette_path = Path.join(@cassette_dir, "multiple_commands.json")
      {:ok, content} = File.read(cassette_path)
      %{"commands" => recordings, "ports" => []} = Jason.decode!(content)

      assert length(recordings) == 2
    end
  end

  describe "record modes" do
    test "record: :new always re-records" do
      # First recording
      use_cmd_cassette "force_record", record: :new do
        System.cmd("echo", ["original"])
      end

      # Second recording with :new should overwrite
      use_cmd_cassette "force_record", record: :new do
        System.cmd("echo", ["updated"])
      end

      cassette_path = Path.join(@cassette_dir, "force_record.json")
      {:ok, content} = File.read(cassette_path)
      %{"commands" => [recording], "ports" => []} = Jason.decode!(content)

      assert recording["args"] == ["updated"]
    end

    test "record: :none raises when cassette is missing" do
      assert_raise ExCliVcr.CassetteNotFoundError, fn ->
        use_cmd_cassette "nonexistent", record: :none do
          System.cmd("echo", ["test"])
        end
      end
    end

    test "record: :none raises when command is not in cassette" do
      # First, create a cassette with one command
      use_cmd_cassette "partial_cassette" do
        System.cmd("echo", ["recorded"])
      end

      # Now try to replay with a different command - should fail
      assert_raise ExCliVcr.CassetteNotFoundError, ~r/No recording found/, fn ->
        use_cmd_cassette "partial_cassette", record: :none do
          System.cmd("echo", ["not_recorded"])
        end
      end
    end

    test "record: :none raises when additional commands are called beyond recorded" do
      # Create a cassette with one command
      use_cmd_cassette "single_command" do
        System.cmd("echo", ["first"])
      end

      # Try to call more commands than recorded - second command should fail
      assert_raise ExCliVcr.CassetteNotFoundError, ~r/No recording found/, fn ->
        use_cmd_cassette "single_command", record: :none do
          # First call succeeds (matches recording)
          {output, 0} = System.cmd("echo", ["first"])
          assert output == "first\n"

          # Second call with different args should fail
          System.cmd("echo", ["second"])
        end
      end
    end

    test "raises when called with different args on replay" do
      # First run: record a command
      use_cmd_cassette "different_args" do
        {output, 0} = System.cmd("echo", ["original"])
        assert output == "original\n"
      end

      # Second run: same cassette but different args should fail
      assert_raise ExCliVcr.CassetteNotFoundError, ~r/No recording found/, fn ->
        use_cmd_cassette "different_args" do
          System.cmd("echo", ["different"])
        end
      end
    end

    test "record: :none allows replaying same command multiple times" do
      # Create a cassette with one command
      use_cmd_cassette "repeatable" do
        System.cmd("echo", ["repeatable"])
      end

      # Same command can be called multiple times (matches the recording)
      use_cmd_cassette "repeatable", record: :none do
        {output1, 0} = System.cmd("echo", ["repeatable"])
        {output2, 0} = System.cmd("echo", ["repeatable"])

        assert output1 == "repeatable\n"
        assert output2 == "repeatable\n"
      end
    end
  end

  describe "System.cmd outside cassette" do
    test "passes through to real System.cmd when not in cassette block" do
      {output, exit_code} = System.cmd("echo", ["passthrough"])
      assert output == "passthrough\n"
      assert exit_code == 0
    end
  end

  describe "command with options" do
    test "records commands with cd option" do
      use_cmd_cassette "with_cd" do
        {output, 0} = System.cmd("pwd", [], cd: "/tmp")
        # Output should contain /tmp or /private/tmp (macOS)
        assert String.contains?(output, "tmp")
      end
    end

    test "records commands with environment variables" do
      use_cmd_cassette "with_env" do
        {output, 0} = System.cmd("sh", ["-c", "echo $MY_VAR"], env: [{"MY_VAR", "test_value"}])
        assert String.trim(output) == "test_value"
      end
    end
  end

  describe "exit codes" do
    test "records non-zero exit codes" do
      use_cmd_cassette "exit_code" do
        {_output, exit_code} = System.cmd("sh", ["-c", "exit 42"])
        assert exit_code == 42
      end

      # Verify it's recorded correctly
      cassette_path = Path.join(@cassette_dir, "exit_code.json")
      {:ok, content} = File.read(cassette_path)
      %{"commands" => [recording], "ports" => []} = Jason.decode!(content)

      assert recording["exit_code"] == 42
    end
  end
end
