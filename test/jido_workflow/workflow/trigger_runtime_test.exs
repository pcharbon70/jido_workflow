defmodule JidoWorkflow.Workflow.TriggerRuntimeTestActions.Echo do
  use Jido.Action,
    name: "trigger_runtime_echo",
    schema: [
      value: [type: :string, required: true]
    ]

  @impl true
  def run(%{value: value}, _context) do
    {:ok, %{"echo" => value}}
  end
end

defmodule JidoWorkflow.Workflow.TriggerRuntimeTest do
  use ExUnit.Case, async: true

  alias Jido.Signal
  alias Jido.Signal.Bus
  alias JidoWorkflow.Workflow.Registry, as: WorkflowRegistry
  alias JidoWorkflow.Workflow.TriggerRuntime
  alias JidoWorkflow.Workflow.TriggerSupervisor

  setup do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "jido_workflow_trigger_runtime_test_#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(tmp)
    File.mkdir_p!(tmp)

    bus = unique_name("trigger_runtime_bus")
    start_supervised!({Bus, name: bus})

    workflow_registry = unique_name("trigger_runtime_registry")

    {:ok, workflow_registry_pid} =
      start_supervised({WorkflowRegistry, workflow_dir: tmp, name: workflow_registry})

    process_registry = unique_name("trigger_runtime_process_registry")
    start_supervised!({Registry, keys: :unique, name: process_registry})

    trigger_supervisor = unique_name("trigger_runtime_supervisor")
    start_supervised!({TriggerSupervisor, name: trigger_supervisor})

    on_exit(fn -> File.rm_rf!(tmp) end)

    {:ok,
     tmp_dir: tmp,
     bus: bus,
     workflow_registry: workflow_registry_pid,
     process_registry: process_registry,
     trigger_supervisor: trigger_supervisor}
  end

  test "refresh/1 syncs triggers and runs workflows from signal/manual sources", context do
    write_trigger_workflow(context.tmp_dir, "runtime_flow")
    runtime_name = unique_name("trigger_runtime")

    runtime =
      start_supervised!(
        {TriggerRuntime,
         name: runtime_name,
         workflow_registry: context.workflow_registry,
         trigger_supervisor: context.trigger_supervisor,
         process_registry: context.process_registry,
         bus: context.bus,
         sync_on_start: false}
      )

    assert {:ok, %{triggers: trigger_summary}} = TriggerRuntime.refresh(runtime)
    assert trigger_summary.started == 2
    assert trigger_summary.errors == []

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
                        "workflow_id" => "runtime_flow",
                        "result" => %{"echo" => "from_signal"}
                      }
                    }},
                   5_000

    assert {:ok, execution} =
             TriggerSupervisor.trigger_manual(
               "runtime_flow:manual:1",
               %{"value" => "from_manual"},
               supervisor: context.trigger_supervisor,
               process_registry: context.process_registry
             )

    assert execution.status == :completed
    assert execution.result == %{"echo" => "from_manual"}

    status = TriggerRuntime.status(runtime)
    assert status.last_error == nil
    assert is_list(status.trigger_ids)
    assert status.last_sync_at != nil
  end

  test "refresh/1 removes stale trigger processes after workflow deletion", context do
    path = write_trigger_workflow(context.tmp_dir, "runtime_stale_flow")
    runtime_name = unique_name("trigger_runtime")

    runtime =
      start_supervised!(
        {TriggerRuntime,
         name: runtime_name,
         workflow_registry: context.workflow_registry,
         trigger_supervisor: context.trigger_supervisor,
         process_registry: context.process_registry,
         bus: context.bus,
         sync_on_start: false}
      )

    assert {:ok, %{triggers: first_sync}} = TriggerRuntime.refresh(runtime)
    assert first_sync.started == 2

    File.rm!(path)

    assert {:ok, %{triggers: second_sync}} = TriggerRuntime.refresh(runtime)
    assert second_sync.stopped == 2
    assert second_sync.desired == 0

    assert_eventually(fn ->
      TriggerSupervisor.list_trigger_ids(process_registry: context.process_registry) == []
    end)
  end

  test "refresh/1 loads triggers from global trigger config file", context do
    write_workflow_without_triggers(context.tmp_dir, "runtime_configured_flow")

    triggers_config_path =
      write_triggers_config(context.tmp_dir, %{
        "triggers" => [
          %{
            "id" => "runtime:signal:external",
            "workflow_id" => "runtime_configured_flow",
            "type" => "signal",
            "enabled" => true,
            "config" => %{"patterns" => ["workflow.runtime.external.requested"]}
          },
          %{
            "id" => "runtime:manual:external",
            "workflow_id" => "runtime_configured_flow",
            "type" => "manual",
            "enabled" => true
          }
        ]
      })

    runtime_name = unique_name("trigger_runtime")

    runtime =
      start_supervised!(
        {TriggerRuntime,
         name: runtime_name,
         workflow_registry: context.workflow_registry,
         trigger_supervisor: context.trigger_supervisor,
         process_registry: context.process_registry,
         bus: context.bus,
         triggers_config_path: triggers_config_path,
         sync_on_start: false}
      )

    assert {:ok, %{triggers: trigger_summary}} = TriggerRuntime.refresh(runtime)
    assert trigger_summary.started == 2
    assert trigger_summary.errors == []

    assert {:ok, _sub_id} =
             Bus.subscribe(context.bus, "workflow.run.*", dispatch: {:pid, target: self()})

    assert {:ok, _published} =
             Bus.publish(context.bus, [
               Signal.new!(
                 "workflow.runtime.external.requested",
                 %{"value" => "from_runtime_file"},
                 source: "/test"
               )
             ])

    assert_receive {:signal,
                    %Signal{
                      type: "workflow.run.completed",
                      data: %{
                        "workflow_id" => "runtime_configured_flow",
                        "result" => %{"echo" => "from_runtime_file"}
                      }
                    }},
                   5_000

    assert {:ok, execution} =
             TriggerSupervisor.trigger_manual(
               "runtime:manual:external",
               %{"value" => "from_runtime_manual"},
               supervisor: context.trigger_supervisor,
               process_registry: context.process_registry
             )

    assert execution.status == :completed
    assert execution.result == %{"echo" => "from_runtime_manual"}

    status = TriggerRuntime.status(runtime)
    assert status.triggers_config_path == triggers_config_path
  end

  test "refresh/1 respects global max_concurrent_triggers setting", context do
    write_trigger_workflow(context.tmp_dir, "runtime_limited_flow")

    triggers_config_path =
      write_triggers_config(context.tmp_dir, %{
        "global_settings" => %{
          "max_concurrent_triggers" => 1
        }
      })

    runtime_name = unique_name("trigger_runtime")

    runtime =
      start_supervised!(
        {TriggerRuntime,
         name: runtime_name,
         workflow_registry: context.workflow_registry,
         trigger_supervisor: context.trigger_supervisor,
         process_registry: context.process_registry,
         bus: context.bus,
         triggers_config_path: triggers_config_path,
         sync_on_start: false}
      )

    assert_eventually(
      fn ->
        case TriggerRuntime.refresh(runtime) do
          {:ok, %{triggers: trigger_summary}} ->
            trigger_summary.configured == 2 and
              trigger_summary.desired == 1 and
              trigger_summary.limited == 1 and
              trigger_summary.max_concurrent_triggers == 1 and
              trigger_summary.errors == []

          _ ->
            false
        end
      end,
      2_000
    )

    assert_eventually(
      fn ->
        TriggerSupervisor.list_trigger_ids(process_registry: context.process_registry) == [
          "runtime_limited_flow:signal:0"
        ]
      end,
      2_000
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
    - **module**: JidoWorkflow.Workflow.TriggerRuntimeTestActions.Echo
    - **inputs**:
      - value: `input:value`

    ## Return
    - **value**: echo
    """

    File.write!(path, markdown)
    path
  end

  defp write_workflow_without_triggers(dir, name) do
    path = Path.join(dir, "#{name}.md")

    markdown = """
    ---
    name: #{name}
    version: "1.0.0"
    enabled: true
    ---

    # #{name}

    ## Steps

    ### echo
    - **type**: action
    - **module**: JidoWorkflow.Workflow.TriggerRuntimeTestActions.Echo
    - **inputs**:
      - value: `input:value`

    ## Return
    - **value**: echo
    """

    File.write!(path, markdown)
    path
  end

  defp write_triggers_config(dir, payload) do
    path = Path.join(dir, "triggers.json")
    File.write!(path, Jason.encode!(payload))
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
