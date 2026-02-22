defmodule Jido.Code.Workflow.RuntimeAgent do
  @moduledoc """
  Minimal runtime agent for executing compiled workflows via `Jido.Runic.Strategy`.
  """

  use Jido.Agent,
    name: "workflow_runtime",
    strategy: Jido.Runic.Strategy,
    schema: [
      status: [type: :atom, default: :idle],
      last_answer: [type: :any, default: nil],
      error: [type: :any, default: nil]
    ]

  @doc false
  def plugin_specs, do: []
end
