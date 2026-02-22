defmodule Jido.Code.Workflow.MixTasks.WorkflowCommandTestActions.Echo do
  use Jido.Action,
    name: "mix_task_workflow_command_echo",
    schema: [
      value: [type: :string, required: true]
    ]

  @impl true
  def run(%{value: value}, _context) do
    {:ok, %{"echo" => value}}
  end
end

defmodule Mix.Tasks.Workflow.CommandTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Jido.Code.Workflow.CommandRuntime
  alias Jido.Code.Workflow.Registry, as: WorkflowRegistry
  alias Jido.Code.Workflow.RunStore
  alias Jido.Code.Workflow.TriggerRuntime
  alias Jido.Code.Workflow.TriggerSupervisor
  alias Jido.Signal.Bus
  alias Mix.Tasks.Workflow.Command

  setup do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "jido_workflow_mix_task_command_test_#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(tmp_dir)
    File.mkdir_p!(tmp_dir)

    write_workflow(tmp_dir, "task_command_flow", "/workflow:review")
    write_workflow(tmp_dir, "task_command_alt", "/workflow:review")

    bus = unique_name("mix_task_command_bus")
    start_supervised!({Bus, name: bus})

    workflow_registry_name = unique_name("mix_task_command_registry")

    workflow_registry =
      start_supervised!({WorkflowRegistry, workflow_dir: tmp_dir, name: workflow_registry_name})

    run_store = unique_name("mix_task_command_run_store")
    start_supervised!({RunStore, name: run_store})

    trigger_process_registry = unique_name("mix_task_command_trigger_process_registry")
    start_supervised!({Registry, keys: :unique, name: trigger_process_registry})

    trigger_supervisor = unique_name("mix_task_command_trigger_supervisor")
    start_supervised!({TriggerSupervisor, name: trigger_supervisor})

    trigger_runtime_name = unique_name("mix_task_command_trigger_runtime")

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

    command_runtime_name = unique_name("mix_task_command_runtime")

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
    assert {:ok, _runtime_summary} = TriggerRuntime.refresh(trigger_runtime)

    on_exit(fn ->
      Mix.Task.reenable("workflow.command")
      Mix.Task.reenable("workflow.signal")
      File.rm_rf!(tmp_dir)
    end)

    {:ok, bus: bus, run_store: run_store}
  end

  test "publishes command requests and executes matching manual trigger", context do
    output =
      capture_io(fn ->
        Command.run([
          "/workflow:review",
          "--workflow-id",
          "task_command_alt",
          "--params",
          ~s({"value":"from_command_task"}),
          "--no-start-app",
          "--no-pretty",
          "--bus",
          Atom.to_string(context.bus)
        ])
      end)

    payload = Jason.decode!(output)
    run_id = get_in(payload, ["response", "data", "run_id"])

    assert payload["status"] == "accepted"
    assert get_in(payload, ["request", "type"]) == "workflow.trigger.manual.requested"

    assert get_in(payload, ["request", "data"]) == %{
             "command" => "/workflow:review",
             "workflow_id" => "task_command_alt",
             "params" => %{"value" => "from_command_task"}
           }

    assert get_in(payload, ["response", "type"]) == "workflow.trigger.manual.accepted"
    assert get_in(payload, ["response", "data", "workflow_id"]) == "task_command_alt"
    assert get_in(payload, ["response", "data", "status"]) == "completed"
    assert is_binary(run_id)
  end

  test "rejects ambiguous command requests without workflow disambiguation", context do
    output =
      capture_io(fn ->
        assert_raise Mix.Error, ~r/Signal rejected: workflow\.trigger\.manual\.rejected/, fn ->
          Command.run([
            "/workflow:review",
            "--params",
            ~s({"value":"from_ambiguous_command"}),
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
    assert get_in(payload, ["response", "type"]) == "workflow.trigger.manual.rejected"
    assert get_in(payload, ["response", "data", "command"]) == "/workflow:review"

    assert String.contains?(
             get_in(payload, ["response", "data", "reason"]),
             "ambiguous_manual_command"
           )
  end

  test "requires a command positional argument", context do
    assert_raise Mix.Error, ~r/Usage: mix workflow\.command <command> \[options\]/, fn ->
      capture_io(fn ->
        Command.run([
          "--no-start-app",
          "--no-pretty",
          "--bus",
          Atom.to_string(context.bus)
        ])
      end)
    end
  end

  test "validates --params as a JSON object", context do
    assert_raise Mix.Error, ~r/--params must decode to a JSON object/, fn ->
      capture_io(fn ->
        Command.run([
          "/workflow:review",
          "--params",
          "[]",
          "--no-start-app",
          "--no-pretty",
          "--bus",
          Atom.to_string(context.bus)
        ])
      end)
    end
  end

  defp write_workflow(dir, workflow_name, command) do
    markdown = """
    ---
    name: #{workflow_name}
    version: "1.0.0"
    enabled: true
    triggers:
      - type: manual
        command: "#{command}"
    ---

    # #{workflow_name}

    ## Steps

    ### echo
    - **type**: action
    - **module**: Jido.Code.Workflow.MixTasks.WorkflowCommandTestActions.Echo
    - **inputs**:
      - value: `input:value`

    ## Return
    - **value**: echo
    """

    path = Path.join(dir, "#{workflow_name}.md")
    File.write!(path, markdown)
    path
  end

  defp unique_name(prefix) do
    :"#{prefix}_#{System.unique_integer([:positive])}"
  end
end
