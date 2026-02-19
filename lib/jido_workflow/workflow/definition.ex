defmodule JidoWorkflow.Workflow.Definition.Input do
  @moduledoc """
  Workflow input declaration.
  """

  @enforce_keys [:name, :type]
  defstruct [:name, :type, :required, :default, :description]

  @type t :: %__MODULE__{
          name: String.t(),
          type: String.t(),
          required: boolean(),
          default: term(),
          description: String.t() | nil
        }
end

defmodule JidoWorkflow.Workflow.Definition.Trigger do
  @moduledoc """
  Workflow trigger declaration.
  """

  @enforce_keys [:type]
  defstruct [:type, :patterns, :events, :schedule, :command, :debounce_ms]

  @type t :: %__MODULE__{
          type: String.t(),
          patterns: [String.t()] | nil,
          events: [String.t()] | nil,
          schedule: String.t() | nil,
          command: String.t() | nil,
          debounce_ms: integer() | nil
        }
end

defmodule JidoWorkflow.Workflow.Definition.RetryPolicy do
  @moduledoc """
  Retry configuration for workflow execution.
  """

  defstruct [:max_retries, :backoff, :base_delay_ms]

  @type t :: %__MODULE__{
          max_retries: non_neg_integer() | nil,
          backoff: String.t() | nil,
          base_delay_ms: non_neg_integer() | nil
        }
end

defmodule JidoWorkflow.Workflow.Definition.Settings do
  @moduledoc """
  Workflow runtime settings.
  """

  defstruct [:max_concurrency, :timeout_ms, :retry_policy, :on_failure]

  @type t :: %__MODULE__{
          max_concurrency: pos_integer() | nil,
          timeout_ms: pos_integer() | nil,
          retry_policy: JidoWorkflow.Workflow.Definition.RetryPolicy.t() | nil,
          on_failure: String.t() | nil
        }
end

defmodule JidoWorkflow.Workflow.Definition.Channel do
  @moduledoc """
  Workflow channel/broadcast configuration.
  """

  defstruct [:topic, :broadcast_events]

  @type t :: %__MODULE__{
          topic: String.t() | nil,
          broadcast_events: [String.t()] | nil
        }
end

defmodule JidoWorkflow.Workflow.Definition.Step do
  @moduledoc """
  Normalized workflow step declaration.
  """

  @enforce_keys [:name, :type]
  defstruct [
    :name,
    :type,
    :module,
    :agent,
    :workflow,
    :callback_signal,
    :inputs,
    :outputs,
    :depends_on,
    :async,
    :optional,
    :mode,
    :timeout_ms,
    :max_retries,
    :pre_actions,
    :post_actions,
    :condition,
    :parallel
  ]

  @type t :: %__MODULE__{
          name: String.t(),
          type: String.t(),
          module: String.t() | nil,
          agent: String.t() | nil,
          workflow: String.t() | nil,
          callback_signal: String.t() | nil,
          inputs: map() | nil,
          outputs: [String.t()] | nil,
          depends_on: [String.t()] | nil,
          async: boolean() | nil,
          optional: boolean() | nil,
          mode: String.t() | nil,
          timeout_ms: integer() | nil,
          max_retries: integer() | nil,
          pre_actions: [map()] | nil,
          post_actions: [map()] | nil,
          condition: String.t() | nil,
          parallel: boolean() | nil
        }
end

defmodule JidoWorkflow.Workflow.Definition.Return do
  @moduledoc """
  Return-value declaration for a workflow.
  """

  defstruct [:value, :transform]

  @type t :: %__MODULE__{
          value: String.t() | nil,
          transform: String.t() | nil
        }
end

defmodule JidoWorkflow.Workflow.Definition do
  @moduledoc """
  In-memory contract for a workflow definition.
  """

  alias JidoWorkflow.Workflow.Definition.{
    Channel,
    Input,
    Return,
    Settings,
    Step,
    Trigger
  }

  @enforce_keys [:name, :version]
  defstruct [
    :name,
    :version,
    :description,
    :enabled,
    :inputs,
    :triggers,
    :settings,
    :channel,
    :steps,
    :error_handling,
    :return
  ]

  @type t :: %__MODULE__{
          name: String.t(),
          version: String.t(),
          description: String.t() | nil,
          enabled: boolean(),
          inputs: [Input.t()],
          triggers: [Trigger.t()],
          settings: Settings.t() | nil,
          channel: Channel.t() | nil,
          steps: [Step.t()],
          error_handling: [map()],
          return: Return.t() | nil
        }
end
