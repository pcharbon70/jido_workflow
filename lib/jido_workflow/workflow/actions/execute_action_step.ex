defmodule JidoWorkflow.Workflow.Actions.ExecuteActionStep do
  @moduledoc """
  Transitional action adapter used by compiled action workflow steps.

  It preserves step metadata and echoes the received payload. Future phases will
  replace this with real action dispatch and argument resolution.
  """

  use Jido.Action,
    name: "workflow_execute_action_step",
    description: "Execute a compiled workflow action step",
    schema: [
      step: [type: :map, required: true]
    ]

  @impl true
  def run(%{step: step} = params, _context) do
    payload = Map.delete(params, :step)

    {:ok,
     %{
       step: fetch(step, :name),
       type: fetch(step, :type),
       module: fetch(step, :module),
       payload: payload
     }}
  end

  defp fetch(step, key) when is_map(step) do
    Map.get(step, key, Map.get(step, Atom.to_string(key)))
  end
end
