defmodule Jido.Code.Workflow.Hooks.Adapter do
  @moduledoc """
  Behavior for workflow hook adapters.
  """

  @callback run(hook_name :: atom(), payload :: map()) :: :ok | {:ok, term()} | {:error, term()}
end
