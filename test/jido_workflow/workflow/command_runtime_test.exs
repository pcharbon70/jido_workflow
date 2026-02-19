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

defmodule JidoWorkflow.Workflow.CommandRuntimeTestActions.DelayedValue do
  use Jido.Action,
    name: "command_runtime_delayed_value",
    schema: [
      value: [type: :string, required: true],
      delay_ms: [type: :integer, required: false, default: 250]
    ]

  @impl true
  def run(%{value: value, delay_ms: delay_ms}, _context) do
    Process.sleep(delay_ms)
    {:ok, %{"value" => value}}
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
          "workflow.run.cancel.*",
          "workflow.run.get.*",
          "workflow.run.list.*",
          "workflow.runtime.status.*"
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

  test "returns run details for workflow.run.get.requested", context do
    assert :ok =
             RunStore.record_started(
               %{run_id: "run_get", workflow_id: "command_flow", backend: :direct},
               context.run_store
             )

    assert :ok =
             RunStore.record_completed(
               "run_get",
               %{"ok" => true},
               %{workflow_id: "command_flow", backend: :direct},
               context.run_store
             )

    assert {:ok, _published} =
             Bus.publish(context.bus, [
               Signal.new!("workflow.run.get.requested", %{"run_id" => "run_get"},
                 source: "/test/client"
               )
             ])

    assert_receive {:signal,
                    %Signal{
                      type: "workflow.run.get.accepted",
                      data: %{
                        "run" => %{
                          "run_id" => "run_get",
                          "workflow_id" => "command_flow",
                          "status" => "completed",
                          "backend" => "direct",
                          "result" => %{"ok" => true}
                        }
                      }
                    }},
                   5_000
  end

  test "returns filtered runs for workflow.run.list.requested", context do
    assert :ok =
             RunStore.record_started(
               %{run_id: "run_list_1", workflow_id: "flow_a", backend: :direct},
               context.run_store
             )

    assert :ok =
             RunStore.record_failed(
               "run_list_1",
               :boom,
               %{workflow_id: "flow_a", backend: :direct},
               context.run_store
             )

    assert :ok =
             RunStore.record_started(
               %{run_id: "run_list_2", workflow_id: "flow_a", backend: :strategy},
               context.run_store
             )

    assert {:ok, _published} =
             Bus.publish(context.bus, [
               Signal.new!(
                 "workflow.run.list.requested",
                 %{"workflow_id" => "flow_a", "status" => "failed", "limit" => 1},
                 source: "/test/client"
               )
             ])

    assert_receive {:signal,
                    %Signal{
                      type: "workflow.run.list.accepted",
                      data: %{"count" => 1, "runs" => [run]}
                    }},
                   5_000

    assert run["run_id"] == "run_list_1"
    assert run["workflow_id"] == "flow_a"
    assert run["status"] == "failed"
  end

  test "returns command runtime status for workflow.runtime.status.requested", context do
    assert {:ok, _published} =
             Bus.publish(context.bus, [
               Signal.new!("workflow.runtime.status.requested", %{}, source: "/test/client")
             ])

    assert_receive {:signal,
                    %Signal{
                      type: "workflow.runtime.status.accepted",
                      data: %{
                        "status" => %{
                          "subscription_count" => subscription_count,
                          "run_tasks" => %{}
                        }
                      }
                    }},
                   5_000

    assert subscription_count >= 7
  end

  test "pauses and resumes live strategy runs through runic controls", context do
    write_strategy_workflow(context.tmp_dir, "strategy_control_flow")
    assert {:ok, _summary} = WorkflowRegistry.refresh(context.workflow_registry)

    run_id = "run_strategy_control_1"

    assert {:ok, _published} =
             Bus.publish(context.bus, [
               Signal.new!(
                 "workflow.run.start.requested",
                 %{
                   "workflow_id" => "strategy_control_flow",
                   "backend" => "strategy",
                   "run_id" => run_id,
                   "inputs" => %{"value" => "hello", "delay_ms" => 250}
                 },
                 source: "/test/client"
               )
             ])

    assert_receive {:signal,
                    %Signal{
                      type: "workflow.run.start.accepted",
                      data: %{"workflow_id" => "strategy_control_flow", "run_id" => ^run_id}
                    }},
                   5_000

    assert_receive {:signal,
                    %Signal{
                      type: "workflow.run.started",
                      data: %{"workflow_id" => "strategy_control_flow", "run_id" => ^run_id}
                    }},
                   10_000

    assert_eventually(fn ->
      status = CommandRuntime.status(context.command_runtime)
      task = get_in(status, [:run_tasks, run_id])
      is_map(task) and task.backend == :strategy and is_pid(task.runtime_agent_pid)
    end)

    assert {:ok, _published} =
             Bus.publish(context.bus, [
               Signal.new!("workflow.run.pause.requested", %{"run_id" => run_id},
                 source: "/test/client"
               )
             ])

    assert_receive {:signal,
                    %Signal{
                      type: "workflow.run.pause.accepted",
                      data: %{"run_id" => ^run_id, "workflow_id" => "strategy_control_flow"}
                    }},
                   5_000

    assert_receive {:signal,
                    %Signal{
                      type: "workflow.run.paused",
                      data: %{"run_id" => ^run_id, "status" => "paused"}
                    }},
                   5_000

    Process.sleep(500)
    assert {:ok, paused_run} = RunStore.get(run_id, context.run_store)
    assert paused_run.status == :paused

    refute_receive {:signal,
                    %Signal{type: "workflow.run.completed", data: %{"run_id" => ^run_id}}}

    assert {:ok, _published} =
             Bus.publish(context.bus, [
               Signal.new!("workflow.run.resume.requested", %{"run_id" => run_id},
                 source: "/test/client"
               )
             ])

    assert_receive {:signal,
                    %Signal{
                      type: "workflow.run.resume.accepted",
                      data: %{"run_id" => ^run_id, "workflow_id" => "strategy_control_flow"}
                    }},
                   5_000

    assert_receive {:signal,
                    %Signal{
                      type: "workflow.run.resumed",
                      data: %{"run_id" => ^run_id, "status" => "running"}
                    }},
                   5_000

    assert_eventually(
      fn ->
        case RunStore.get(run_id, context.run_store) do
          {:ok, run} -> run.status in [:running, :completed]
          _ -> false
        end
      end,
      10_000
    )

    assert {:ok, run_after_resume} = RunStore.get(run_id, context.run_store)
    assert run_after_resume.status in [:running, :completed]
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

  defp write_strategy_workflow(dir, workflow_name) do
    markdown = """
    ---
    name: #{workflow_name}
    version: "1.0.0"
    enabled: true
    ---

    # #{workflow_name}

    ## Steps

    ### delayed
    - **type**: action
    - **module**: JidoWorkflow.Workflow.CommandRuntimeTestActions.DelayedValue
    - **inputs**:
      - value: `input:value`
      - delay_ms: `input:delay_ms`

    ### echo
    - **type**: action
    - **module**: JidoWorkflow.Workflow.CommandRuntimeTestActions.Echo
    - **depends_on**: [delayed]
    - **inputs**:
      - value: `result:delayed.value`

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

  defp assert_eventually(fun, timeout_ms \\ 1_000) when is_function(fun, 0) do
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
