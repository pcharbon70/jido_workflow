defmodule Mix.Tasks.Workflow.ControlTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Jido.Code.Workflow.CommandRuntime
  alias Jido.Code.Workflow.Registry, as: WorkflowRegistry
  alias Jido.Code.Workflow.RunStore
  alias Jido.Code.Workflow.TriggerRuntime
  alias Jido.Code.Workflow.TriggerSupervisor
  alias Jido.Signal.Bus
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

  test "definitions action maps to workflow.definition.list.requested", context do
    output =
      capture_io(fn ->
        Control.run([
          "definitions",
          "--include-disabled",
          "false",
          "--include-invalid",
          "false",
          "--limit",
          "2",
          "--no-start-app",
          "--no-pretty",
          "--bus",
          Atom.to_string(context.bus)
        ])
      end)

    payload = Jason.decode!(output)

    assert payload["status"] == "accepted"
    assert get_in(payload, ["request", "type"]) == "workflow.definition.list.requested"

    assert get_in(payload, ["request", "data"]) == %{
             "include_disabled" => false,
             "include_invalid" => false,
             "limit" => 2
           }

    assert get_in(payload, ["response", "type"]) == "workflow.definition.list.accepted"
  end

  test "registry-refresh action maps to workflow.registry.refresh.requested", context do
    output =
      capture_io(fn ->
        Control.run([
          "registry-refresh",
          "--no-start-app",
          "--no-pretty",
          "--bus",
          Atom.to_string(context.bus)
        ])
      end)

    payload = Jason.decode!(output)

    assert payload["status"] == "accepted"
    assert get_in(payload, ["request", "type"]) == "workflow.registry.refresh.requested"
    assert get_in(payload, ["response", "type"]) == "workflow.registry.refresh.accepted"
  end

  test "trigger-runtime-status action maps to workflow.trigger.runtime.status.requested",
       context do
    output =
      capture_io(fn ->
        Control.run([
          "trigger-runtime-status",
          "--no-start-app",
          "--no-pretty",
          "--bus",
          Atom.to_string(context.bus)
        ])
      end)

    payload = Jason.decode!(output)

    assert payload["status"] == "accepted"
    assert get_in(payload, ["request", "type"]) == "workflow.trigger.runtime.status.requested"
    assert get_in(payload, ["response", "type"]) == "workflow.trigger.runtime.status.accepted"
  end

  test "trigger-manual action maps to workflow.trigger.manual.requested", context do
    output =
      capture_io(fn ->
        assert_raise Mix.Error, ~r/Signal rejected: workflow\.trigger\.manual\.rejected/, fn ->
          Control.run([
            "trigger-manual",
            "--command",
            "/workflow:unknown",
            "--workflow-id",
            "missing_flow",
            "--params",
            ~s({"value":"hello"}),
            "--no-start-app",
            "--no-pretty",
            "--bus",
            Atom.to_string(context.bus)
          ])
        end
      end)

    payload = Jason.decode!(output)

    assert payload["status"] == "rejected"
    assert get_in(payload, ["request", "type"]) == "workflow.trigger.manual.requested"

    assert get_in(payload, ["request", "data"]) == %{
             "command" => "/workflow:unknown",
             "workflow_id" => "missing_flow",
             "params" => %{"value" => "hello"}
           }
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

  test "trigger-manual requires command or trigger-id", context do
    assert_raise Mix.Error, ~r/trigger-manual requires one of: --trigger-id, --command/, fn ->
      capture_io(fn ->
        Control.run([
          "trigger-manual",
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
