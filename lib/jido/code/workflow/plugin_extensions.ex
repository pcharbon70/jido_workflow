defmodule Jido.Code.Workflow.PluginExtensions do
  @moduledoc """
  Extension points for plugin-defined workflow step and trigger types.
  """

  alias Jido.Code.Workflow.StepTypeRegistry
  alias Jido.Code.Workflow.TriggerTypeRegistry

  @spec register_step_type(String.t() | atom(), module()) :: :ok | {:error, term()}
  def register_step_type(type_name, step_module) do
    StepTypeRegistry.register(type_name, step_module)
  end

  @spec unregister_step_type(String.t() | atom()) :: :ok
  def unregister_step_type(type_name) do
    StepTypeRegistry.unregister(type_name)
  end

  @spec register_trigger_type(String.t() | atom(), module()) :: :ok | {:error, term()}
  def register_trigger_type(type_name, trigger_module) do
    TriggerTypeRegistry.register(type_name, trigger_module)
  end

  @spec unregister_trigger_type(String.t() | atom()) :: :ok
  def unregister_trigger_type(type_name) do
    TriggerTypeRegistry.unregister(type_name)
  end

  @spec supported_step_types() :: [String.t()]
  def supported_step_types do
    StepTypeRegistry.supported_types()
  end

  @spec supported_trigger_types() :: [String.t()]
  def supported_trigger_types do
    TriggerTypeRegistry.supported_types()
  end
end
