defmodule JidoWorkflow.Workflow.CommandRuntimeTestActions.Echo do
  use Jido.Action,
    name: "command_runtime_echo",
    schema: [
      value: [type: :string, required: true]
    ]

  @impl true
  def run(%{value: value}, _context) do
    {:ok, %{"echo" => value}}
  end
end

defmodule JidoWorkflow.Workflow.CommandRuntimeTest do
  use ExUnit.Case, async: true

  alias Jido.Signal
  alias Jido.Signal.Bus
  alias JidoWorkflow.Workflow.CommandRuntime
  alias JidoWorkflow.Workflow.Registry, as: WorkflowRegistry
  alias JidoWorkflow.Workflow.RunStore

  setup do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "jido_workflow_command_runtime_test_#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(tmp)
    File.mkdir_p!(tmp)

    bus = unique_name("command_runtime_bus")
    start_supervised!({Bus, name: bus})

    workflow_registry = unique_name("command_runtime_registry")

    workflow_registry_pid =
      start_supervised!({WorkflowRegistry, workflow_dir: tmp, name: workflow_registry})

    run_store = unique_name("command_runtime_run_store")
    start_supervised!({RunStore, name: run_store})

    command_runtime = unique_name("command_runtime")

    runtime_pid =
      start_supervised!(
        {CommandRuntime,
         name: command_runtime,
         bus: bus,
         workflow_registry: workflow_registry_pid,
         run_store: run_store}
      )

    for pattern <- [
          "workflow.run.*",
          "workflow.run.start.*",
          "workflow.run.pause.*",
          "workflow.run.resume.*",
          "workflow.run.cancel.*"
        ] do
      assert {:ok, _sub_id} = Bus.subscribe(bus, pattern, dispatch: {:pid, target: self()})
    end

    on_exit(fn -> File.rm_rf!(tmp) end)

    {:ok,
     tmp_dir: tmp,
     bus: bus,
     workflow_registry: workflow_registry_pid,
     run_store: run_store,
     command_runtime: runtime_pid}
  end

  test "handles workflow.run.start.requested and executes workflow asynchronously", context do
    write_workflow(context.tmp_dir, "command_flow")

    assert {:ok, _summary} = WorkflowRegistry.refresh(context.workflow_registry)

    assert {:ok, _published} =
             Bus.publish(context.bus, [
               Signal.new!(
                 "workflow.run.start.requested",
                 %{
                   "workflow_id" => "command_flow",
                   "inputs" => %{"value" => "hello"}
                 },
                 source: "/test/client"
               )
             ])

    assert_receive {:signal,
                    %Signal{
                      type: "workflow.run.start.accepted",
                      data: %{"workflow_id" => "command_flow", "run_id" => run_id}
                    }},
                   5_000

    assert_receive {:signal,
                    %Signal{
                      type: "workflow.run.started",
                      data: %{"workflow_id" => "command_flow", "run_id" => ^run_id}
                    }},
                   5_000

    assert_receive {:signal,
                    %Signal{
                      type: "workflow.run.completed",
                      data: %{
                        "workflow_id" => "command_flow",
                        "run_id" => ^run_id,
                        "result" => %{"echo" => "hello"}
                      }
                    }},
                   5_000

    assert {:ok, run} = RunStore.get(run_id, context.run_store)
    assert run.status == :completed
    assert run.workflow_id == "command_flow"
  end

  test "emits start rejected when requested workflow is not available", context do
    assert {:ok, _published} =
             Bus.publish(context.bus, [
               Signal.new!(
                 "workflow.run.start.requested",
                 %{
                   "workflow_id" => "missing_workflow",
                   "inputs" => %{"value" => "hello"}
                 },
                 source: "/test/client"
               )
             ])

    assert_receive {:signal,
                    %Signal{
                      type: "workflow.run.start.rejected",
                      data: %{
                        "workflow_id" => "missing_workflow",
                        "reason" => reason
                      }
                    }},
                   5_000

    assert String.contains?(reason, "workflow_not_available")
  end

  test "routes pause/resume/cancel command signals through run controls", context do
    assert :ok =
             RunStore.record_started(
               %{run_id: "run_ctrl", workflow_id: "command_flow", backend: :direct},
               context.run_store
             )

    assert {:ok, _published} =
             Bus.publish(context.bus, [
               Signal.new!("workflow.run.pause.requested", %{"run_id" => "run_ctrl"},
                 source: "/test/client"
               )
             ])

    assert_receive {:signal,
                    %Signal{
                      type: "workflow.run.pause.accepted",
                      data: %{"run_id" => "run_ctrl", "workflow_id" => "command_flow"}
                    }},
                   5_000

    assert_receive {:signal,
                    %Signal{
                      type: "workflow.run.paused",
                      data: %{"run_id" => "run_ctrl", "status" => "paused"}
                    }},
                   5_000

    assert {:ok, _published} =
             Bus.publish(context.bus, [
               Signal.new!("workflow.run.resume.requested", %{"run_id" => "run_ctrl"},
                 source: "/test/client"
               )
             ])

    assert_receive {:signal,
                    %Signal{
                      type: "workflow.run.resume.accepted",
                      data: %{"run_id" => "run_ctrl", "workflow_id" => "command_flow"}
                    }},
                   5_000

    assert_receive {:signal,
                    %Signal{
                      type: "workflow.run.resumed",
                      data: %{"run_id" => "run_ctrl", "status" => "running"}
                    }},
                   5_000

    assert {:ok, _published} =
             Bus.publish(context.bus, [
               Signal.new!(
                 "workflow.run.cancel.requested",
                 %{"run_id" => "run_ctrl", "reason" => "manual_stop"},
                 source: "/test/client"
               )
             ])

    assert_receive {:signal,
                    %Signal{
                      type: "workflow.run.cancel.accepted",
                      data: %{"run_id" => "run_ctrl", "workflow_id" => "command_flow"}
                    }},
                   5_000

    assert_receive {:signal,
                    %Signal{
                      type: "workflow.run.cancelled",
                      data: %{
                        "run_id" => "run_ctrl",
                        "status" => "cancelled",
                        "reason" => "manual_stop"
                      }
                    }},
                   5_000

    assert {:ok, run} = RunStore.get("run_ctrl", context.run_store)
    assert run.status == :cancelled
    assert run.error == "manual_stop"
  end

  test "emits cancel rejected when transition is invalid", context do
    assert :ok =
             RunStore.record_completed(
               "run_done",
               %{"ok" => true},
               %{workflow_id: "command_flow", backend: :direct},
               context.run_store
             )

    assert {:ok, _published} =
             Bus.publish(context.bus, [
               Signal.new!("workflow.run.cancel.requested", %{"run_id" => "run_done"},
                 source: "/test/client"
               )
             ])

    assert_receive {:signal,
                    %Signal{
                      type: "workflow.run.cancel.rejected",
                      data: %{"run_id" => "run_done", "reason" => reason}
                    }},
                   5_000

    assert String.contains?(reason, "invalid_transition")
  end

  defp write_workflow(dir, workflow_name) do
    markdown = """
    ---
    name: #{workflow_name}
    version: "1.0.0"
    enabled: true
    ---

    # #{workflow_name}

    ## Steps

    ### echo
    - **type**: action
    - **module**: JidoWorkflow.Workflow.CommandRuntimeTestActions.Echo
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
