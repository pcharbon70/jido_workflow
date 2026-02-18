defmodule JidoWorkflow.Workflow.ValidationError do
  @moduledoc """
  Structured validation error returned by workflow contract validation.
  """

  @enforce_keys [:path, :code, :message]
  defstruct [:path, :code, :message]

  @type t :: %__MODULE__{
          path: [String.t()],
          code: atom(),
          message: String.t()
        }
end
