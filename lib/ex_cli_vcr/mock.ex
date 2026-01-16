defmodule ExCliVcr.Mock do
  @moduledoc """
  Provides functions to intercept System.cmd calls during testing.

  There are two main approaches to use ExCliVcr:

  ## Approach 1: Use ExCliVcr.cmd/3 directly (Recommended)

  Replace calls to `System.cmd/3` with `ExCliVcr.cmd/3` in your code,
  or use dependency injection:

      defmodule MyModule do
        def run_command(cmd_fn \\\\ &System.cmd/3) do
          cmd_fn.("echo", ["hello"], [])
        end
      end

      # In test:
      use_cassette "my_test" do
        MyModule.run_command(&ExCliVcr.cmd/3)
      end

  ## Approach 2: Module replacement via Application config

  Configure a command module in your config:

      # config/config.exs
      config :my_app, :cmd_module, System

      # config/test.exs
      config :my_app, :cmd_module, ExCliVcr

  Then in your code:

      @cmd_module Application.compile_env(:my_app, :cmd_module, System)

      def run_command do
        @cmd_module.cmd("echo", ["hello"], [])
      end

  ## Approach 3: Global mock (for legacy code)

  Use `ExCliVcr.Mock.install/0` in your test_helper.exs to globally
  redirect all System.cmd calls. Note: This uses process dictionary
  and only works for the current process.
  """

  @doc """
  Install a global mock for System.cmd.

  This stores a flag in the process dictionary that ExCliVcr.cmd/3 uses
  to determine whether to intercept calls.

  Call this in your test setup:

      setup do
        ExCliVcr.Mock.install()
        :ok
      end
  """
  def install do
    Process.put(:cli_vcr_mock_installed, true)
    :ok
  end

  @doc """
  Uninstall the global mock.
  """
  def uninstall do
    Process.delete(:cli_vcr_mock_installed)
    :ok
  end

  @doc """
  Check if the mock is installed.
  """
  def installed? do
    Process.get(:cli_vcr_mock_installed, false)
  end
end

defmodule ExCliVcr.Cmd do
  @moduledoc """
  Behaviour for command execution.

  Implement this behaviour to create testable modules that execute commands.
  """

  @callback cmd(binary(), [binary()], keyword()) :: {Collectable.t(), exit_status :: non_neg_integer()}
end
