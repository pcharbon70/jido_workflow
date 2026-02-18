defmodule JidoWorkflow.Workflow.TriggerTestActions.Echo do
  use Jido.Action,
    name: "trigger_echo",
    schema: [
      value: [type: :string, required: true]
    ]

  @impl true
  def run(%{value: value}, _context) do
    {:ok, %{"echo" => value}}
  end
end

defmodule JidoWorkflow.Workflow.TriggerManagerTest do
  use ExUnit.Case, async: true

  alias Jido.Signal
  alias Jido.Signal.Bus
  alias JidoWorkflow.Workflow.Registry, as: WorkflowRegistry
  alias JidoWorkflow.Workflow.TriggerManager
  alias JidoWorkflow.Workflow.TriggerSupervisor

  setup do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "jido_workflow_trigger_manager_test_#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(tmp)
    File.mkdir_p!(tmp)

    bus = unique_name("trigger_bus")
    start_supervised!({Bus, name: bus})

    workflow_registry = unique_name("workflow_registry")

    {:ok, workflow_registry_pid} =
      start_supervised({WorkflowRegistry, workflow_dir: tmp, name: workflow_registry})

    process_registry = unique_name("trigger_process_registry")
    start_supervised!({Registry, keys: :unique, name: process_registry})

    trigger_supervisor = unique_name("trigger_supervisor")
    start_supervised!({TriggerSupervisor, name: trigger_supervisor})

    on_exit(fn -> File.rm_rf!(tmp) end)

    {:ok,
     tmp_dir: tmp,
     bus: bus,
     workflow_registry: workflow_registry_pid,
     process_registry: process_registry,
     trigger_supervisor: trigger_supervisor}
  end

  test "sync_from_registry starts signal/manual triggers and executes workflows", context do
    write_trigger_workflow(context.tmp_dir, "triggered_flow")
    assert {:ok, %{total: 1}} = WorkflowRegistry.refresh(context.workflow_registry)

    assert {:ok, summary} =
             TriggerManager.sync_from_registry(
               workflow_registry: context.workflow_registry,
               trigger_supervisor: context.trigger_supervisor,
               process_registry: context.process_registry,
               bus: context.bus
             )

    assert summary.started == 2
    assert summary.stopped == 0
    assert summary.unsupported == 0
    assert summary.errors == []

    assert TriggerSupervisor.list_trigger_ids(process_registry: context.process_registry) == [
             "triggered_flow:manual:1",
             "triggered_flow:signal:0"
           ]

    assert {:ok, _sub_id} =
             Bus.subscribe(context.bus, "workflow.run.*", dispatch: {:pid, target: self()})

    assert {:ok, _published} =
             Bus.publish(context.bus, [
               Signal.new!("workflow.trigger.requested", %{"value" => "from_signal"},
                 source: "/test"
               )
             ])

    assert_receive {:signal,
                    %Signal{
                      type: "workflow.run.completed",
                      data: %{
                        "workflow_id" => "triggered_flow",
                        "result" => %{"echo" => "from_signal"}
                      }
                    }},
                   5_000

    assert {:ok, execution} =
             TriggerSupervisor.trigger_manual(
               "triggered_flow:manual:1",
               %{"value" => "from_manual"},
               supervisor: context.trigger_supervisor,
               process_registry: context.process_registry
             )

    assert execution.status == :completed
    assert execution.workflow_id == "triggered_flow"
    assert execution.result == %{"echo" => "from_manual"}
  end

  test "sync_from_registry stops stale triggers after workflow removal", context do
    path = write_trigger_workflow(context.tmp_dir, "stale_flow")
    assert {:ok, %{total: 1}} = WorkflowRegistry.refresh(context.workflow_registry)

    assert {:ok, first_sync} =
             TriggerManager.sync_from_registry(
               workflow_registry: context.workflow_registry,
               trigger_supervisor: context.trigger_supervisor,
               process_registry: context.process_registry,
               bus: context.bus
             )

    assert first_sync.started == 2

    assert length(TriggerSupervisor.list_trigger_ids(process_registry: context.process_registry)) ==
             2

    File.rm!(path)
    assert {:ok, %{removed: 1, total: 0}} = WorkflowRegistry.refresh(context.workflow_registry)

    assert {:ok, second_sync} =
             TriggerManager.sync_from_registry(
               workflow_registry: context.workflow_registry,
               trigger_supervisor: context.trigger_supervisor,
               process_registry: context.process_registry,
               bus: context.bus
             )

    assert second_sync.stopped == 2
    assert second_sync.desired == 0

    assert_eventually(fn ->
      TriggerSupervisor.list_trigger_ids(process_registry: context.process_registry) == []
    end)
  end

  test "trigger supervisor returns unsupported type errors", context do
    assert {:error, {:unsupported_trigger_type, "webhook"}} =
             TriggerSupervisor.start_trigger(
               %{id: "x:webhook:0", workflow_id: "x", type: "webhook"},
               supervisor: context.trigger_supervisor,
               process_registry: context.process_registry
             )
  end

  defp write_trigger_workflow(dir, name) do
    path = Path.join(dir, "#{name}.md")

    markdown = """
    ---
    name: #{name}
    version: "1.0.0"
    enabled: true
    triggers:
      - type: signal
        patterns: ["workflow.trigger.requested"]
      - type: manual
        command: "/workflow:#{name}"
    ---

    # #{name}

    ## Steps

    ### echo
    - **type**: action
    - **module**: JidoWorkflow.Workflow.TriggerTestActions.Echo
    - **inputs**:
      - value: `input:value`

    ## Return
    - **value**: echo
    """

    File.write!(path, markdown)
    path
  end

  defp unique_name(prefix) do
    :"#{prefix}_#{System.unique_integer([:positive])}"
  end

  defp assert_eventually(fun, timeout_ms \\ 500) when is_function(fun, 0) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_assert_eventually(fun, deadline)
  end

  defp do_assert_eventually(fun, deadline) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) < deadline do
        Process.sleep(10)
        do_assert_eventually(fun, deadline)
      else
        assert fun.()
      end
    end
  end
end
