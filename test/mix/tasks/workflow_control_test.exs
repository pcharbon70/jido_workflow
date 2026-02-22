defmodule Mix.Tasks.Workflow.ControlTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Jido.Signal.Bus
  alias JidoWorkflow.Workflow.CommandRuntime
  alias JidoWorkflow.Workflow.Registry, as: WorkflowRegistry
  alias JidoWorkflow.Workflow.RunStore
  alias JidoWorkflow.Workflow.TriggerRuntime
  alias JidoWorkflow.Workflow.TriggerSupervisor
  alias Mix.Tasks.Workflow.Control

  setup do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "jido_workflow_mix_task_control_test_#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(tmp_dir)
    File.mkdir_p!(tmp_dir)

    bus = unique_name("mix_task_control_bus")
    start_supervised!({Bus, name: bus})

    workflow_registry_name = unique_name("mix_task_control_registry")

    workflow_registry =
      start_supervised!({WorkflowRegistry, workflow_dir: tmp_dir, name: workflow_registry_name})

    run_store = unique_name("mix_task_control_run_store")
    start_supervised!({RunStore, name: run_store})

    trigger_process_registry = unique_name("mix_task_control_trigger_process_registry")
    start_supervised!({Registry, keys: :unique, name: trigger_process_registry})

    trigger_supervisor = unique_name("mix_task_control_trigger_supervisor")
    start_supervised!({TriggerSupervisor, name: trigger_supervisor})

    trigger_runtime_name = unique_name("mix_task_control_trigger_runtime")

    trigger_runtime =
      start_supervised!(
        {TriggerRuntime,
         name: trigger_runtime_name,
         workflow_registry: workflow_registry,
         trigger_supervisor: trigger_supervisor,
         process_registry: trigger_process_registry,
         bus: bus,
         sync_on_start: false}
      )

    command_runtime_name = unique_name("mix_task_control_command_runtime")

    start_supervised!(
      {CommandRuntime,
       name: command_runtime_name,
       bus: bus,
       workflow_registry: workflow_registry,
       run_store: run_store,
       trigger_supervisor: trigger_supervisor,
       trigger_process_registry: trigger_process_registry,
       trigger_runtime: trigger_runtime}
    )

    assert {:ok, _summary} = WorkflowRegistry.refresh(workflow_registry)

    on_exit(fn ->
      Mix.Task.reenable("workflow.control")
      Mix.Task.reenable("workflow.signal")
      File.rm_rf!(tmp_dir)
    end)

    {:ok, bus: bus}
  end

  test "list action maps to workflow.run.list.requested and returns accepted", context do
    output =
      capture_io(fn ->
        Control.run([
          "list",
          "--no-start-app",
          "--no-pretty",
          "--bus",
          Atom.to_string(context.bus),
          "--workflow-id",
          "sample_flow",
          "--status",
          "running",
          "--limit",
          "5"
        ])
      end)

    payload = Jason.decode!(output)

    assert payload["status"] == "accepted"
    assert get_in(payload, ["request", "type"]) == "workflow.run.list.requested"

    assert get_in(payload, ["request", "data"]) == %{
             "limit" => 5,
             "status" => "running",
             "workflow_id" => "sample_flow"
           }

    assert get_in(payload, ["response", "type"]) == "workflow.run.list.accepted"
  end

  test "runtime-status action maps to workflow.runtime.status.requested", context do
    output =
      capture_io(fn ->
        Control.run([
          "runtime-status",
          "--no-start-app",
          "--no-pretty",
          "--bus",
          Atom.to_string(context.bus)
        ])
      end)

    payload = Jason.decode!(output)

    assert payload["status"] == "accepted"
    assert get_in(payload, ["request", "type"]) == "workflow.runtime.status.requested"
    assert get_in(payload, ["response", "type"]) == "workflow.runtime.status.accepted"
  end

  test "cancel action forwards reason in rejected request payload", context do
    output =
      capture_io(fn ->
        assert_raise Mix.Error, ~r/Signal rejected: workflow\.run\.cancel\.rejected/, fn ->
          Control.run([
            "cancel",
            "missing_run",
            "--reason",
            "user_requested",
            "--no-start-app",
            "--no-pretty",
            "--bus",
            Atom.to_string(context.bus)
          ])
        end
      end)

    payload = Jason.decode!(output)
    assert payload["status"] == "rejected"
    assert get_in(payload, ["request", "type"]) == "workflow.run.cancel.requested"
    assert get_in(payload, ["request", "data", "reason"]) == "user_requested"
  end

  test "mode action requires --mode", context do
    assert_raise Mix.Error, ~r/--mode is required when action is mode/, fn ->
      capture_io(fn ->
        Control.run([
          "mode",
          "run_123",
          "--no-start-app",
          "--no-pretty",
          "--bus",
          Atom.to_string(context.bus)
        ])
      end)
    end
  end

  defp unique_name(prefix) do
    :"#{prefix}_#{System.unique_integer([:positive])}"
  end
end
