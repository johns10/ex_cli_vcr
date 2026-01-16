defmodule ExCliVcr.CassetteNotFoundError do
  @moduledoc """
  Error raised when no matching recording is found in a cassette.
  """
  defexception [:message]
end
