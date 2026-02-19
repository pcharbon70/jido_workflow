defmodule JidoWorkflow.Workflow.Hooks.NoopAdapter do
  @moduledoc """
  Default no-op workflow hook adapter.
  """

  @behaviour JidoWorkflow.Workflow.Hooks.Adapter

  @impl true
  def run(_hook_name, _payload), do: :ok
end
