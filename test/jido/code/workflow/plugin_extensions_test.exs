defmodule Jido.Code.Workflow.PluginExtensionsTestCustomStep do
  use Jido.Action,
    name: "plugin_extensions_custom_step",
    schema: [
      step: [type: :map, required: true]
    ]

  @impl true
  def run(%{step: step}, _context) do
    type = Map.get(step, "type") || Map.get(step, :type)
    {:ok, %{"type" => type}}
  end
end

defmodule Jido.Code.Workflow.PluginExtensionsTestCustomTrigger do
  use GenServer

  @spec start_link(map()) :: GenServer.on_start()
  def start_link(config) do
    GenServer.start_link(__MODULE__, config, name: via_tuple(config))
  end

  @impl true
  def init(config), do: {:ok, config}

  defp via_tuple(config) do
    trigger_id = fetch(config, "id")
    process_registry = fetch(config, "process_registry")
    {:via, Registry, {process_registry, trigger_id}}
  end

  defp fetch(map, key) when is_map(map) and is_binary(key) do
    Map.get(map, key) || Map.get(map, String.to_atom(key))
  end
end

defmodule Jido.Code.Workflow.PluginExtensionsTest do
  use ExUnit.Case, async: false

  alias Jido.Code.Workflow.Compiler
  alias Jido.Code.Workflow.Definition
  alias Jido.Code.Workflow.Definition.Step, as: DefinitionStep
  alias Jido.Code.Workflow.PluginExtensions
  alias Jido.Code.Workflow.TriggerSupervisor
  alias Jido.Code.Workflow.Validator
  alias Jido.Runic.ActionNode
  alias Runic.Workflow

  setup do
    original_step_types = Application.get_env(:jido_workflow, :workflow_step_types, %{})
    original_trigger_types = Application.get_env(:jido_workflow, :workflow_trigger_types, %{})

    on_exit(fn ->
      Application.put_env(:jido_workflow, :workflow_step_types, original_step_types)
      Application.put_env(:jido_workflow, :workflow_trigger_types, original_trigger_types)
    end)

    :ok
  end

  test "register_step_type/2 extends validator and compiler for custom step types" do
    assert :ok =
             PluginExtensions.register_step_type(
               "custom_skill",
               Jido.Code.Workflow.PluginExtensionsTestCustomStep
             )

    assert {:ok, _definition} =
             Validator.validate(%{
               "name" => "custom_step_workflow",
               "version" => "1.0.0",
               "steps" => [
                 %{"name" => "skill_step", "type" => "custom_skill"}
               ]
             })

    definition =
      base_definition([
        %DefinitionStep{
          name: "skill_step",
          type: "custom_skill",
          module: nil,
          agent: nil,
          workflow: nil,
          callback_signal: nil,
          inputs: %{"topic" => "workflow"},
          outputs: nil,
          depends_on: [],
          async: nil,
          optional: nil,
          mode: nil,
          timeout_ms: nil,
          max_retries: nil,
          pre_actions: nil,
          post_actions: nil,
          condition: nil,
          parallel: nil
        }
      ])

    assert {:ok, compiled} = Compiler.compile(definition)

    assert %ActionNode{
             name: "skill_step",
             action_mod: Jido.Code.Workflow.PluginExtensionsTestCustomStep,
             params: %{step: %{type: "custom_skill"}}
           } = Workflow.get_component(compiled.workflow, "skill_step")
  end

  test "register_step_type/2 rejects reserved built-in step type names" do
    assert {:error, {:reserved_step_type, "skill"}} =
             PluginExtensions.register_step_type(
               "skill",
               Jido.Code.Workflow.PluginExtensionsTestCustomStep
             )
  end

  test "register_trigger_type/2 extends validator and trigger supervisor for custom trigger types" do
    process_registry = unique_name("plugin_extensions_trigger_registry")
    start_supervised!({Registry, keys: :unique, name: process_registry})

    trigger_supervisor = unique_name("plugin_extensions_trigger_supervisor")
    start_supervised!({TriggerSupervisor, name: trigger_supervisor})

    assert :ok =
             PluginExtensions.register_trigger_type(
               "webhook",
               Jido.Code.Workflow.PluginExtensionsTestCustomTrigger
             )

    assert {:ok, _definition} =
             Validator.validate(%{
               "name" => "custom_trigger_workflow",
               "version" => "1.0.0",
               "triggers" => [
                 %{"type" => "webhook"}
               ],
               "steps" => []
             })

    assert {:ok, _pid} =
             TriggerSupervisor.start_trigger(
               %{
                 id: "custom:webhook:0",
                 workflow_id: "custom",
                 type: "webhook"
               },
               supervisor: trigger_supervisor,
               process_registry: process_registry
             )

    assert TriggerSupervisor.list_trigger_ids(process_registry: process_registry) == [
             "custom:webhook:0"
           ]
  end

  defp base_definition(steps) do
    %Definition{
      name: "plugin_extensions_workflow",
      version: "1.0.0",
      description: "plugin extensions",
      enabled: true,
      inputs: [],
      triggers: [],
      settings: nil,
      signals: nil,
      steps: steps,
      error_handling: [],
      return: nil
    }
  end

  defp unique_name(prefix) do
    :"#{prefix}_#{System.unique_integer([:positive])}"
  end
end
