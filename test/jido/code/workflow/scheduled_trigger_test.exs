defmodule Jido.Code.Workflow.ScheduledTriggerTestActions.CaptureTrigger do
  use Jido.Action,
    name: "scheduled_capture_trigger",
    schema: [
      trigger_type: [type: :string, required: true],
      trigger_id: [type: :string, required: true],
      schedule: [type: :string, required: true]
    ]

  @impl true
  def run(%{trigger_type: trigger_type, trigger_id: trigger_id, schedule: schedule}, _context) do
    {:ok,
     %{
       "trigger_type" => trigger_type,
       "trigger_id" => trigger_id,
       "schedule" => schedule
     }}
  end
end

defmodule Jido.Code.Workflow.ScheduledTriggerTest do
  use ExUnit.Case, async: true

  alias Jido.Code.Workflow.Registry, as: WorkflowRegistry
  alias Jido.Code.Workflow.TriggerManager
  alias Jido.Code.Workflow.TriggerSupervisor
  alias Jido.Signal
  alias Jido.Signal.Bus

  setup do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "jido_workflow_scheduled_trigger_test_#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(tmp)
    File.mkdir_p!(tmp)

    bus = unique_name("scheduled_trigger_bus")
    start_supervised!({Bus, name: bus})

    workflow_registry = unique_name("scheduled_trigger_registry")

    {:ok, workflow_registry_pid} =
      start_supervised({WorkflowRegistry, workflow_dir: tmp, name: workflow_registry})

    process_registry = unique_name("scheduled_trigger_process_registry")
    start_supervised!({Registry, keys: :unique, name: process_registry})

    trigger_supervisor = unique_name("scheduled_trigger_supervisor")
    start_supervised!({TriggerSupervisor, name: trigger_supervisor})

    on_exit(fn -> File.rm_rf!(tmp) end)

    {:ok,
     tmp_dir: tmp,
     bus: bus,
     workflow_registry: workflow_registry_pid,
     process_registry: process_registry,
     trigger_supervisor: trigger_supervisor}
  end

  test "sync_from_registry starts scheduled triggers and runs workflows", context do
    write_scheduled_workflow(context.tmp_dir, "scheduled_flow", "*/1 * * * * *")
    assert {:ok, %{total: 1}} = WorkflowRegistry.refresh(context.workflow_registry)

    assert {:ok, _sub_id} =
             Bus.subscribe(context.bus, "workflow.run.completed",
               dispatch: {:pid, target: self()}
             )

    assert {:ok, summary} =
             TriggerManager.sync_from_registry(
               workflow_registry: context.workflow_registry,
               trigger_supervisor: context.trigger_supervisor,
               process_registry: context.process_registry,
               bus: context.bus
             )

    assert summary.started == 1
    assert summary.errors == []

    assert TriggerSupervisor.list_trigger_ids(process_registry: context.process_registry) == [
             "scheduled_flow:scheduled:0"
           ]

    assert_receive {:signal,
                    %Signal{
                      type: "workflow.run.completed",
                      data: %{
                        "workflow_id" => "scheduled_flow",
                        "result" => %{
                          "trigger_type" => "scheduled",
                          "trigger_id" => "scheduled_flow:scheduled:0",
                          "schedule" => "*/1 * * * * *"
                        }
                      }
                    }},
                   5_000
  end

  test "scheduled trigger rejects invalid cron expressions", context do
    assert {:error, {:invalid_schedule, _reason}} =
             TriggerSupervisor.start_trigger(
               %{
                 id: "scheduled_flow:scheduled:0",
                 workflow_id: "scheduled_flow",
                 type: "scheduled",
                 schedule: "not-a-cron",
                 workflow_registry: context.workflow_registry,
                 bus: context.bus
               },
               supervisor: context.trigger_supervisor,
               process_registry: context.process_registry
             )
  end

  defp write_scheduled_workflow(dir, name, schedule) do
    path = Path.join(dir, "#{name}.md")

    markdown = """
    ---
    name: #{name}
    version: "1.0.0"
    enabled: true
    triggers:
      - type: scheduled
        schedule: "#{schedule}"
    ---

    # #{name}

    ## Steps

    ### capture_trigger
    - **type**: action
    - **module**: Jido.Code.Workflow.ScheduledTriggerTestActions.CaptureTrigger
    - **inputs**:
      - trigger_type: `input:trigger_type`
      - trigger_id: `input:trigger_id`
      - schedule: `input:schedule`

    ## Return
    - **value**: capture_trigger
    """

    File.write!(path, markdown)
    path
  end

  defp unique_name(prefix) do
    :"#{prefix}_#{System.unique_integer([:positive])}"
  end
end
