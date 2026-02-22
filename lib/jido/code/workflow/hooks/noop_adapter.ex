defmodule Jido.Code.Workflow.Hooks.NoopAdapter do
  @moduledoc """
  Default no-op workflow hook adapter.
  """

  @behaviour Jido.Code.Workflow.Hooks.Adapter

  @impl true
  def run(_hook_name, _payload), do: :ok
end
