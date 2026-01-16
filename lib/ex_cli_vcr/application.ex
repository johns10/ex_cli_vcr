defmodule ExCliVcr.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      ExCliVcr.Recorder
    ]

    opts = [strategy: :one_for_one, name: ExCliVcr.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
