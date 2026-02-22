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

defmodule JidoWorkflow.Workflow.CommandRuntimeTestActions.EchoWithIdProbe do
  use Jido.Action,
    name: "command_runtime_echo_with_id_probe",
    schema: [
      value: [type: :string, required: true],
      id: [type: :any, required: false]
    ]

  @impl true
  def run(%{value: value} = params, _context) do
    {:ok, %{"echo" => value, "id_seen" => Map.get(params, :id)}}
  end
end

defmodule JidoWorkflow.Workflow.CommandRuntimeTest do
  use ExUnit.Case, async: true

  alias Jido.Signal
  alias Jido.Signal.Bus
  alias JidoWorkflow.Workflow.CommandRuntime
  alias JidoWorkflow.Workflow.Registry, as: WorkflowRegistry
  alias JidoWorkflow.Workflow.RunStore
  alias JidoWorkflow.Workflow.TriggerRuntime
  alias JidoWorkflow.Workflow.TriggerSupervisor

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

    trigger_process_registry = unique_name("command_runtime_trigger_process_registry")
    start_supervised!({Registry, keys: :unique, name: trigger_process_registry})

    trigger_supervisor = unique_name("command_runtime_trigger_supervisor")
    start_supervised!({TriggerSupervisor, name: trigger_supervisor})

    trigger_runtime = unique_name("command_runtime_trigger_runtime")

    trigger_runtime_pid =
      start_supervised!(
        {TriggerRuntime,
         name: trigger_runtime,
         workflow_registry: workflow_registry_pid,
         trigger_supervisor: trigger_supervisor,
         process_registry: trigger_process_registry,
         bus: bus,
         sync_on_start: false}
      )

    command_runtime = unique_name("command_runtime")

    runtime_pid =
      start_supervised!(
        {CommandRuntime,
         name: command_runtime,
         bus: bus,
         workflow_registry: workflow_registry_pid,
         run_store: run_store,
         trigger_supervisor: trigger_supervisor,
         trigger_process_registry: trigger_process_registry,
         trigger_runtime: trigger_runtime_pid}
      )

    for pattern <- [
          "workflow.run.*",
          "workflow.run.start.*",
          "workflow.run.pause.*",
          "workflow.run.step.*",
          "workflow.run.mode.*",
          "workflow.run.resume.*",
          "workflow.run.cancel.*",
          "workflow.run.get.*",
          "workflow.run.list.*",
          "workflow.runtime.status.*",
          "workflow.definition.list.*",
          "workflow.definition.get.*",
          "workflow.registry.refresh.*",
          "workflow.registry.reload.*",
          "workflow.trigger.manual.*",
          "workflow.trigger.refresh.*",
          "workflow.trigger.sync.*",
          "workflow.trigger.runtime.status.*"
        ] do
      assert {:ok, _sub_id} = Bus.subscribe(bus, pattern, dispatch: {:pid, target: self()})
    end

    on_exit(fn -> File.rm_rf!(tmp) end)

    {:ok,
     tmp_dir: tmp,
     bus: bus,
     workflow_registry: workflow_registry_pid,
     run_store: run_store,
     trigger_supervisor: trigger_supervisor,
     trigger_process_registry: trigger_process_registry,
     trigger_runtime: trigger_runtime_pid,
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

  test "handles workflow.run.start.requested with id fallback", context do
    write_workflow(context.tmp_dir, "command_flow_by_id")

    assert {:ok, _summary} = WorkflowRegistry.refresh(context.workflow_registry)

    assert {:ok, _published} =
             Bus.publish(context.bus, [
               Signal.new!(
                 "workflow.run.start.requested",
                 %{
                   "id" => "  command_flow_by_id  ",
                   "run_id" => "  run_start_by_id  ",
                   "inputs" => %{"value" => "hello_by_id"}
                 },
                 source: "/test/client"
               )
             ])

    assert_receive {:signal,
                    %Signal{
                      type: "workflow.run.start.accepted",
                      data: %{
                        "workflow_id" => "command_flow_by_id",
                        "run_id" => "run_start_by_id"
                      }
                    }},
                   5_000

    assert_receive {:signal,
                    %Signal{
                      type: "workflow.run.completed",
                      data: %{
                        "workflow_id" => "command_flow_by_id",
                        "run_id" => "run_start_by_id",
                        "result" => %{"echo" => "hello_by_id"}
                      }
                    }},
                   5_000

    assert {:ok, run} = RunStore.get("run_start_by_id", context.run_store)
    assert run.status == :completed
    assert run.workflow_id == "command_flow_by_id"
  end

  test "does not include id fallback key in implicit workflow.run.start.requested inputs",
       context do
    write_workflow(context.tmp_dir, "command_flow_implicit_inputs")

    assert {:ok, _summary} = WorkflowRegistry.refresh(context.workflow_registry)

    assert {:ok, _published} =
             Bus.publish(context.bus, [
               Signal.new!(
                 "workflow.run.start.requested",
                 %{
                   "id" => "command_flow_implicit_inputs",
                   "run_id" => "run_implicit_start_by_id",
                   "value" => "implicit_value"
                 },
                 source: "/test/client"
               )
             ])

    assert_receive {:signal,
                    %Signal{
                      type: "workflow.run.completed",
                      data: %{
                        "workflow_id" => "command_flow_implicit_inputs",
                        "run_id" => "run_implicit_start_by_id",
                        "result" => %{"echo" => "implicit_value"}
                      }
                    }},
                   5_000

    assert {:ok, run} = RunStore.get("run_implicit_start_by_id", context.run_store)
    assert run.inputs == %{"value" => "implicit_value"}
    refute Map.has_key?(run.inputs, "id")
  end

  test "normalizes whitespace in workflow.run.start.requested values", context do
    write_workflow(context.tmp_dir, "command_flow")
    assert {:ok, _summary} = WorkflowRegistry.refresh(context.workflow_registry)

    assert {:ok, _published} =
             Bus.publish(context.bus, [
               Signal.new!(
                 "workflow.run.start.requested",
                 %{
                   "workflow_id" => "  command_flow  ",
                   "run_id" => "  run_start_whitespace  ",
                   "backend" => "  DIRECT  ",
                   "inputs" => %{"value" => "trimmed_start"}
                 },
                 source: "/test/client"
               )
             ])

    assert_receive {:signal,
                    %Signal{
                      type: "workflow.run.start.accepted",
                      data: %{
                        "workflow_id" => "command_flow",
                        "run_id" => "run_start_whitespace"
                      }
                    }},
                   5_000

    assert_receive {:signal,
                    %Signal{
                      type: "workflow.run.completed",
                      data: %{
                        "workflow_id" => "command_flow",
                        "run_id" => "run_start_whitespace",
                        "result" => %{"echo" => "trimmed_start"}
                      }
                    }},
                   5_000
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

  test "normalizes identifiers in workflow.run.start.rejected payloads", context do
    assert {:ok, _published} =
             Bus.publish(context.bus, [
               Signal.new!(
                 "workflow.run.start.requested",
                 %{
                   "workflow_id" => "  missing_workflow  ",
                   "run_id" => "  run_missing_workflow_ws  ",
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
                        "run_id" => "run_missing_workflow_ws",
                        "reason" => reason
                      }
                    }},
                   5_000

    assert String.contains?(reason, "workflow_not_available")
  end

  test "echoes normalized id fallback in workflow.run.start.rejected payloads", context do
    assert {:ok, _published} =
             Bus.publish(context.bus, [
               Signal.new!(
                 "workflow.run.start.requested",
                 %{
                   "id" => "  missing_by_id_workflow  ",
                   "run_id" => "  run_missing_by_id_ws  ",
                   "inputs" => %{"value" => "hello"}
                 },
                 source: "/test/client"
               )
             ])

    assert_receive {:signal,
                    %Signal{
                      type: "workflow.run.start.rejected",
                      data: %{
                        "workflow_id" => "missing_by_id_workflow",
                        "run_id" => "run_missing_by_id_ws",
                        "reason" => reason
                      }
                    }},
                   5_000

    assert String.contains?(reason, "workflow_not_available")
  end

  test "emits start rejected when requested backend is invalid", context do
    write_workflow(context.tmp_dir, "command_flow")

    assert {:ok, _summary} = WorkflowRegistry.refresh(context.workflow_registry)

    assert {:ok, _published} =
             Bus.publish(context.bus, [
               Signal.new!(
                 "workflow.run.start.requested",
                 %{
                   "workflow_id" => "command_flow",
                   "run_id" => "run_invalid_backend",
                   "backend" => "invalid",
                   "inputs" => %{"value" => "hello"}
                 },
                 source: "/test/client"
               )
             ])

    assert_receive {:signal,
                    %Signal{
                      type: "workflow.run.start.rejected",
                      data: %{
                        "workflow_id" => "command_flow",
                        "run_id" => "run_invalid_backend",
                        "reason" => reason
                      }
                    }},
                   5_000

    assert String.contains?(reason, "missing_or_invalid")
    assert String.contains?(reason, "backend")
    assert {:error, :not_found} = RunStore.get("run_invalid_backend", context.run_store)
    refute_receive {:signal, %Signal{type: "workflow.run.started"}}, 200
  end

  test "emits start rejected when requested run_id already exists", context do
    write_workflow(context.tmp_dir, "command_flow")

    assert {:ok, _summary} = WorkflowRegistry.refresh(context.workflow_registry)

    assert :ok =
             RunStore.record_completed(
               "run_existing",
               %{"echo" => "old"},
               %{workflow_id: "command_flow", backend: :direct, inputs: %{"value" => "old"}},
               context.run_store
             )

    assert {:ok, _published} =
             Bus.publish(context.bus, [
               Signal.new!(
                 "workflow.run.start.requested",
                 %{
                   "workflow_id" => "command_flow",
                   "run_id" => "run_existing",
                   "inputs" => %{"value" => "hello"}
                 },
                 source: "/test/client"
               )
             ])

    assert_receive {:signal,
                    %Signal{
                      type: "workflow.run.start.rejected",
                      data: %{
                        "workflow_id" => "command_flow",
                        "run_id" => "run_existing",
                        "reason" => reason
                      }
                    }},
                   5_000

    assert String.contains?(reason, "run_id_already_exists")

    assert {:ok, run} = RunStore.get("run_existing", context.run_store)
    assert run.status == :completed
    assert run.result == %{"echo" => "old"}
    refute_receive {:signal, %Signal{type: "workflow.run.started"}}, 200
  end

  test "accepts start requests with generated run_id when run_store is unavailable", context do
    write_workflow(context.tmp_dir, "command_flow")
    assert {:ok, _summary} = WorkflowRegistry.refresh(context.workflow_registry)

    missing_run_store = unique_name("command_runtime_missing_run_store")
    _ = :sys.replace_state(context.command_runtime, &Map.put(&1, :run_store, missing_run_store))

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
  end

  test "rejects start requests with explicit run_id when run_store is unavailable", context do
    write_workflow(context.tmp_dir, "command_flow")
    assert {:ok, _summary} = WorkflowRegistry.refresh(context.workflow_registry)

    missing_run_store = unique_name("command_runtime_missing_run_store")
    _ = :sys.replace_state(context.command_runtime, &Map.put(&1, :run_store, missing_run_store))

    assert {:ok, _published} =
             Bus.publish(context.bus, [
               Signal.new!(
                 "workflow.run.start.requested",
                 %{
                   "workflow_id" => "command_flow",
                   "run_id" => "run_unavailable_store",
                   "inputs" => %{"value" => "hello"}
                 },
                 source: "/test/client"
               )
             ])

    assert_receive {:signal,
                    %Signal{
                      type: "workflow.run.start.rejected",
                      data: %{
                        "workflow_id" => "command_flow",
                        "run_id" => "run_unavailable_store",
                        "reason" => reason
                      }
                    }},
                   5_000

    assert String.contains?(reason, "run_store_unavailable")
    refute_receive {:signal, %Signal{type: "workflow.run.started"}}, 200
  end

  test "rejects pause requests when run_store is unavailable without crashing runtime", context do
    missing_run_store = unique_name("command_runtime_missing_run_store")
    _ = :sys.replace_state(context.command_runtime, &Map.put(&1, :run_store, missing_run_store))

    assert {:ok, _published} =
             Bus.publish(context.bus, [
               Signal.new!(
                 "workflow.run.pause.requested",
                 %{"run_id" => "run_pause_missing_store"},
                 source: "/test/client"
               )
             ])

    assert_receive {:signal,
                    %Signal{
                      type: "workflow.run.pause.rejected",
                      data: %{"run_id" => "run_pause_missing_store", "reason" => reason}
                    }},
                   5_000

    assert String.contains?(reason, "run_store_unavailable")
    assert Process.alive?(context.command_runtime)
  end

  test "rejects get requests when run_store is unavailable without crashing runtime", context do
    missing_run_store = unique_name("command_runtime_missing_run_store")
    _ = :sys.replace_state(context.command_runtime, &Map.put(&1, :run_store, missing_run_store))

    assert {:ok, _published} =
             Bus.publish(context.bus, [
               Signal.new!("workflow.run.get.requested", %{"run_id" => "run_get_missing_store"},
                 source: "/test/client"
               )
             ])

    assert_receive {:signal,
                    %Signal{
                      type: "workflow.run.get.rejected",
                      data: %{"run_id" => "run_get_missing_store", "reason" => reason}
                    }},
                   5_000

    assert String.contains?(reason, "run_store_unavailable")
    assert Process.alive?(context.command_runtime)
  end

  test "rejects list requests when run_store is unavailable and remains responsive", context do
    missing_run_store = unique_name("command_runtime_missing_run_store")
    _ = :sys.replace_state(context.command_runtime, &Map.put(&1, :run_store, missing_run_store))

    assert {:ok, _published} =
             Bus.publish(context.bus, [
               Signal.new!("workflow.run.list.requested", %{}, source: "/test/client")
             ])

    assert_receive {:signal,
                    %Signal{
                      type: "workflow.run.list.rejected",
                      data: %{"reason" => reason}
                    }},
                   5_000

    assert String.contains?(reason, "run_store_unavailable")

    assert {:ok, _published} =
             Bus.publish(context.bus, [
               Signal.new!("workflow.runtime.status.requested", %{}, source: "/test/client")
             ])

    assert_receive {:signal,
                    %Signal{
                      type: "workflow.runtime.status.accepted",
                      data: %{"status" => %{"subscription_count" => subscription_count}}
                    }},
                   5_000

    assert subscription_count >= 17
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

  test "normalizes run_id in workflow.run.get.rejected payloads", context do
    assert {:ok, _published} =
             Bus.publish(context.bus, [
               Signal.new!("workflow.run.get.requested", %{"run_id" => "  run_get_missing_ws  "},
                 source: "/test/client"
               )
             ])

    assert_receive {:signal,
                    %Signal{
                      type: "workflow.run.get.rejected",
                      data: %{"run_id" => "run_get_missing_ws", "reason" => reason}
                    }},
                   5_000

    assert String.contains?(reason, "not_found")
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

  test "normalizes whitespace in workflow.run.list.requested filters", context do
    assert :ok =
             RunStore.record_started(
               %{run_id: "run_list_ws_1", workflow_id: "flow_ws", backend: :direct},
               context.run_store
             )

    assert :ok =
             RunStore.record_failed(
               "run_list_ws_1",
               :boom,
               %{workflow_id: "flow_ws", backend: :direct},
               context.run_store
             )

    assert :ok =
             RunStore.record_started(
               %{run_id: "run_list_ws_2", workflow_id: "flow_ws", backend: :strategy},
               context.run_store
             )

    assert {:ok, _published} =
             Bus.publish(context.bus, [
               Signal.new!(
                 "workflow.run.list.requested",
                 %{
                   "workflow_id" => "  flow_ws  ",
                   "status" => "  FAILED  ",
                   "limit" => "  1  "
                 },
                 source: "/test/client"
               )
             ])

    assert_receive {:signal,
                    %Signal{
                      type: "workflow.run.list.accepted",
                      data: %{"count" => 1, "runs" => [run]}
                    }},
                   5_000

    assert run["run_id"] == "run_list_ws_1"
    assert run["workflow_id"] == "flow_ws"
    assert run["status"] == "failed"
  end

  test "supports id fallback in workflow.run.list.requested filters", context do
    assert :ok =
             RunStore.record_started(
               %{run_id: "run_list_id_1", workflow_id: "flow_id", backend: :direct},
               context.run_store
             )

    assert :ok =
             RunStore.record_failed(
               "run_list_id_1",
               :boom,
               %{workflow_id: "flow_id", backend: :direct},
               context.run_store
             )

    assert :ok =
             RunStore.record_started(
               %{run_id: "run_list_id_2", workflow_id: "flow_id", backend: :strategy},
               context.run_store
             )

    assert {:ok, _published} =
             Bus.publish(context.bus, [
               Signal.new!(
                 "workflow.run.list.requested",
                 %{"id" => "  flow_id  ", "status" => "  FAILED  ", "limit" => "  1  "},
                 source: "/test/client"
               )
             ])

    assert_receive {:signal,
                    %Signal{
                      type: "workflow.run.list.accepted",
                      data: %{"count" => 1, "runs" => [run]}
                    }},
                   5_000

    assert run["run_id"] == "run_list_id_1"
    assert run["workflow_id"] == "flow_id"
    assert run["status"] == "failed"
  end

  test "does not use id fallback when workflow_id filter is explicitly provided", context do
    assert {:ok, _published} =
             Bus.publish(context.bus, [
               Signal.new!(
                 "workflow.run.list.requested",
                 %{"workflow_id" => "   ", "id" => "flow_id", "status" => "failed"},
                 source: "/test/client"
               )
             ])

    assert_receive {:signal,
                    %Signal{
                      type: "workflow.run.list.rejected",
                      data: %{"reason" => reason}
                    }},
                   5_000

    assert String.contains?(reason, "missing_or_invalid")
    assert String.contains?(reason, "workflow_id")
  end

  test "rejects workflow.run.list.requested when id fallback filter is invalid", context do
    assert {:ok, _published} =
             Bus.publish(context.bus, [
               Signal.new!(
                 "workflow.run.list.requested",
                 %{"id" => "   ", "status" => "failed"},
                 source: "/test/client"
               )
             ])

    assert_receive {:signal,
                    %Signal{
                      type: "workflow.run.list.rejected",
                      data: %{"reason" => reason}
                    }},
                   5_000

    assert String.contains?(reason, "missing_or_invalid")
    assert String.contains?(reason, "workflow_id")
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

    assert subscription_count >= 17
  end

  test "handles workflow.run.step.requested for active strategy runs", context do
    write_strategy_workflow(context.tmp_dir, "strategy_step_flow")
    assert {:ok, _summary} = WorkflowRegistry.refresh(context.workflow_registry)

    run_id = "run_strategy_step_1"

    assert {:ok, _published} =
             Bus.publish(context.bus, [
               Signal.new!(
                 "workflow.run.start.requested",
                 %{
                   "workflow_id" => "strategy_step_flow",
                   "backend" => "strategy",
                   "run_id" => run_id,
                   "inputs" => %{"value" => "hello", "delay_ms" => 1_500}
                 },
                 source: "/test/client"
               )
             ])

    assert_receive {:signal,
                    %Signal{
                      type: "workflow.run.start.accepted",
                      data: %{"workflow_id" => "strategy_step_flow", "run_id" => ^run_id}
                    }},
                   5_000

    assert_receive {:signal,
                    %Signal{
                      type: "workflow.run.started",
                      data: %{"workflow_id" => "strategy_step_flow", "run_id" => ^run_id}
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
                      data: %{"run_id" => ^run_id, "workflow_id" => "strategy_step_flow"}
                    }},
                   5_000

    assert_receive {:signal,
                    %Signal{
                      type: "workflow.run.paused",
                      data: %{"run_id" => ^run_id, "status" => "paused"}
                    }},
                   5_000

    assert {:ok, _published} =
             Bus.publish(context.bus, [
               Signal.new!("workflow.run.step.requested", %{"run_id" => run_id},
                 source: "/test/client"
               )
             ])

    assert_receive {:signal,
                    %Signal{
                      type: "workflow.run.step.accepted",
                      data: %{"run_id" => ^run_id, "workflow_id" => "strategy_step_flow"}
                    }},
                   5_000
  end

  test "handles workflow.run.mode.requested for active strategy runs", context do
    write_strategy_workflow(context.tmp_dir, "strategy_mode_flow")
    assert {:ok, _summary} = WorkflowRegistry.refresh(context.workflow_registry)

    run_id = "run_strategy_mode_1"

    assert {:ok, _published} =
             Bus.publish(context.bus, [
               Signal.new!(
                 "workflow.run.start.requested",
                 %{
                   "workflow_id" => "strategy_mode_flow",
                   "backend" => "strategy",
                   "run_id" => run_id,
                   "inputs" => %{"value" => "hello", "delay_ms" => 1_500}
                 },
                 source: "/test/client"
               )
             ])

    assert_receive {:signal,
                    %Signal{
                      type: "workflow.run.start.accepted",
                      data: %{"workflow_id" => "strategy_mode_flow", "run_id" => ^run_id}
                    }},
                   5_000

    assert_receive {:signal,
                    %Signal{
                      type: "workflow.run.started",
                      data: %{"workflow_id" => "strategy_mode_flow", "run_id" => ^run_id}
                    }},
                   10_000

    assert_eventually(fn ->
      status = CommandRuntime.status(context.command_runtime)
      task = get_in(status, [:run_tasks, run_id])
      is_map(task) and task.backend == :strategy and is_pid(task.runtime_agent_pid)
    end)

    assert {:ok, _published} =
             Bus.publish(context.bus, [
               Signal.new!(
                 "workflow.run.mode.requested",
                 %{"run_id" => run_id, "mode" => "step"},
                 source: "/test/client"
               )
             ])

    assert_receive {:signal,
                    %Signal{
                      type: "workflow.run.mode.accepted",
                      data: %{
                        "run_id" => ^run_id,
                        "workflow_id" => "strategy_mode_flow",
                        "mode" => "step",
                        "status" => "paused"
                      }
                    }},
                   5_000

    assert_receive {:signal,
                    %Signal{
                      type: "workflow.run.paused",
                      data: %{"run_id" => ^run_id, "status" => "paused"}
                    }},
                   5_000

    assert {:ok, _published} =
             Bus.publish(context.bus, [
               Signal.new!(
                 "workflow.run.mode.requested",
                 %{"run_id" => run_id, "mode" => "auto"},
                 source: "/test/client"
               )
             ])

    assert_receive {:signal,
                    %Signal{
                      type: "workflow.run.mode.accepted",
                      data: %{
                        "run_id" => ^run_id,
                        "workflow_id" => "strategy_mode_flow",
                        "mode" => "auto",
                        "status" => "running"
                      }
                    }},
                   5_000

    assert_receive {:signal,
                    %Signal{
                      type: "workflow.run.resumed",
                      data: %{"run_id" => ^run_id, "status" => "running"}
                    }},
                   5_000
  end

  test "rejects workflow.run.step.requested for non-strategy runs", context do
    assert :ok =
             RunStore.record_started(
               %{run_id: "run_step_direct", workflow_id: "command_flow", backend: :direct},
               context.run_store
             )

    assert {:ok, _published} =
             Bus.publish(context.bus, [
               Signal.new!("workflow.run.step.requested", %{"run_id" => "run_step_direct"},
                 source: "/test/client"
               )
             ])

    assert_receive {:signal,
                    %Signal{
                      type: "workflow.run.step.rejected",
                      data: %{"run_id" => "run_step_direct", "reason" => reason}
                    }},
                   5_000

    assert String.contains?(reason, "unsupported_backend")
  end

  test "rejects workflow.run.mode.requested for non-strategy runs", context do
    assert :ok =
             RunStore.record_started(
               %{run_id: "run_mode_direct", workflow_id: "command_flow", backend: :direct},
               context.run_store
             )

    assert {:ok, _published} =
             Bus.publish(context.bus, [
               Signal.new!(
                 "workflow.run.mode.requested",
                 %{"run_id" => "run_mode_direct", "mode" => "step"},
                 source: "/test/client"
               )
             ])

    assert_receive {:signal,
                    %Signal{
                      type: "workflow.run.mode.rejected",
                      data: %{
                        "run_id" => "run_mode_direct",
                        "mode" => "step",
                        "reason" => reason
                      }
                    }},
                   5_000

    assert String.contains?(reason, "unsupported_backend")
  end

  test "normalizes whitespace in workflow.run.mode.requested payload values", context do
    assert :ok =
             RunStore.record_started(
               %{run_id: "run_mode_ws_direct", workflow_id: "command_flow", backend: :direct},
               context.run_store
             )

    assert {:ok, _published} =
             Bus.publish(context.bus, [
               Signal.new!(
                 "workflow.run.mode.requested",
                 %{"run_id" => "  run_mode_ws_direct  ", "mode" => "  STEP  "},
                 source: "/test/client"
               )
             ])

    assert_receive {:signal,
                    %Signal{
                      type: "workflow.run.mode.rejected",
                      data: %{
                        "run_id" => "run_mode_ws_direct",
                        "mode" => "STEP",
                        "reason" => reason
                      }
                    }},
                   5_000

    assert String.contains?(reason, "unsupported_backend")
  end

  test "returns workflow metadata for workflow.definition.list.requested", context do
    write_workflow(context.tmp_dir, "catalog_flow")
    write_disabled_workflow(context.tmp_dir, "catalog_disabled_flow")
    assert {:ok, _summary} = WorkflowRegistry.refresh(context.workflow_registry)

    assert {:ok, _published} =
             Bus.publish(context.bus, [
               Signal.new!(
                 "workflow.definition.list.requested",
                 %{"include_disabled" => false},
                 source: "/test/client"
               )
             ])

    assert_receive {:signal,
                    %Signal{
                      type: "workflow.definition.list.accepted",
                      data: %{"count" => 1, "definitions" => [definition]}
                    }},
                   5_000

    assert definition["id"] == "catalog_flow"
    assert definition["enabled"] == true
  end

  test "normalizes whitespace in workflow.definition.list.requested boolean and limit filters",
       context do
    write_workflow(context.tmp_dir, "catalog_ws_flow")
    write_disabled_workflow(context.tmp_dir, "catalog_ws_disabled_flow")
    assert {:ok, _summary} = WorkflowRegistry.refresh(context.workflow_registry)

    assert {:ok, _published} =
             Bus.publish(context.bus, [
               Signal.new!(
                 "workflow.definition.list.requested",
                 %{
                   "include_disabled" => "  false  ",
                   "include_invalid" => "  true  ",
                   "limit" => "  1  "
                 },
                 source: "/test/client"
               )
             ])

    assert_receive {:signal,
                    %Signal{
                      type: "workflow.definition.list.accepted",
                      data: %{"count" => 1, "definitions" => [definition]}
                    }},
                   5_000

    assert definition["enabled"] == true
  end

  test "returns workflow definition for workflow.definition.get.requested", context do
    write_workflow(context.tmp_dir, "catalog_get_flow")
    assert {:ok, _summary} = WorkflowRegistry.refresh(context.workflow_registry)

    assert {:ok, _published} =
             Bus.publish(context.bus, [
               Signal.new!(
                 "workflow.definition.get.requested",
                 %{"workflow_id" => "catalog_get_flow"},
                 source: "/test/client"
               )
             ])

    assert_receive {:signal,
                    %Signal{
                      type: "workflow.definition.get.accepted",
                      data: %{
                        "workflow_id" => "catalog_get_flow",
                        "definition" => definition
                      }
                    }},
                   5_000

    assert definition["name"] == "catalog_get_flow"
    assert is_list(definition["steps"])
  end

  test "returns workflow definition for workflow.definition.get.requested with id fallback",
       context do
    write_workflow(context.tmp_dir, "catalog_get_by_id_flow")
    assert {:ok, _summary} = WorkflowRegistry.refresh(context.workflow_registry)

    assert {:ok, _published} =
             Bus.publish(context.bus, [
               Signal.new!(
                 "workflow.definition.get.requested",
                 %{"id" => "  catalog_get_by_id_flow  "},
                 source: "/test/client"
               )
             ])

    assert_receive {:signal,
                    %Signal{
                      type: "workflow.definition.get.accepted",
                      data: %{
                        "workflow_id" => "catalog_get_by_id_flow",
                        "definition" => definition
                      }
                    }},
                   5_000

    assert definition["name"] == "catalog_get_by_id_flow"
  end

  test "rejects workflow.definition.get.requested for unknown workflow", context do
    assert {:ok, _published} =
             Bus.publish(context.bus, [
               Signal.new!(
                 "workflow.definition.get.requested",
                 %{"workflow_id" => "missing_flow"},
                 source: "/test/client"
               )
             ])

    assert_receive {:signal,
                    %Signal{
                      type: "workflow.definition.get.rejected",
                      data: %{"workflow_id" => "missing_flow", "reason" => reason}
                    }},
                   5_000

    assert String.contains?(reason, "not_found")
  end

  test "normalizes workflow_id in workflow.definition.get.rejected payloads", context do
    assert {:ok, _published} =
             Bus.publish(context.bus, [
               Signal.new!(
                 "workflow.definition.get.requested",
                 %{"workflow_id" => "  missing_flow  "},
                 source: "/test/client"
               )
             ])

    assert_receive {:signal,
                    %Signal{
                      type: "workflow.definition.get.rejected",
                      data: %{"workflow_id" => "missing_flow", "reason" => reason}
                    }},
                   5_000

    assert String.contains?(reason, "not_found")
  end

  test "echoes normalized id fallback in workflow.definition.get.rejected payloads", context do
    assert {:ok, _published} =
             Bus.publish(context.bus, [
               Signal.new!(
                 "workflow.definition.get.requested",
                 %{"id" => "  missing_by_id_flow  "},
                 source: "/test/client"
               )
             ])

    assert_receive {:signal,
                    %Signal{
                      type: "workflow.definition.get.rejected",
                      data: %{"workflow_id" => "missing_by_id_flow", "reason" => reason}
                    }},
                   5_000

    assert String.contains?(reason, "not_found")
  end

  test "handles workflow.registry.refresh.requested", context do
    write_workflow(context.tmp_dir, "registry_refresh_flow")

    assert {:ok, _published} =
             Bus.publish(context.bus, [
               Signal.new!("workflow.registry.refresh.requested", %{}, source: "/test/client")
             ])

    assert_receive {:signal,
                    %Signal{
                      type: "workflow.registry.refresh.accepted",
                      data: %{
                        "summary" => %{
                          "workflow_dir" => _workflow_dir,
                          "total" => total
                        }
                      }
                    }},
                   5_000

    assert total >= 1
  end

  test "rejects workflow.registry.refresh.requested when registry is unavailable", context do
    GenServer.stop(context.workflow_registry, :normal)

    assert {:ok, _published} =
             Bus.publish(context.bus, [
               Signal.new!("workflow.registry.refresh.requested", %{}, source: "/test/client")
             ])

    assert_receive {:signal,
                    %Signal{
                      type: "workflow.registry.refresh.rejected",
                      data: %{"reason" => reason}
                    }},
                   5_000

    assert String.contains?(reason, "workflow_registry_unavailable")
  end

  test "handles workflow.registry.reload.requested for a known workflow", context do
    write_workflow(context.tmp_dir, "registry_reload_flow")
    assert {:ok, _summary} = WorkflowRegistry.refresh(context.workflow_registry)

    assert {:ok, _published} =
             Bus.publish(context.bus, [
               Signal.new!(
                 "workflow.registry.reload.requested",
                 %{"workflow_id" => "registry_reload_flow"},
                 source: "/test/client"
               )
             ])

    assert_receive {:signal,
                    %Signal{
                      type: "workflow.registry.reload.accepted",
                      data: %{
                        "workflow_id" => "registry_reload_flow",
                        "summary" => %{
                          "changed" => changed,
                          "total" => total
                        }
                      }
                    }},
                   5_000

    assert changed >= 1
    assert total >= 1
  end

  test "handles workflow.registry.reload.requested for a known workflow with id fallback",
       context do
    write_workflow(context.tmp_dir, "registry_reload_by_id_flow")
    assert {:ok, _summary} = WorkflowRegistry.refresh(context.workflow_registry)

    assert {:ok, _published} =
             Bus.publish(context.bus, [
               Signal.new!(
                 "workflow.registry.reload.requested",
                 %{"id" => "  registry_reload_by_id_flow  "},
                 source: "/test/client"
               )
             ])

    assert_receive {:signal,
                    %Signal{
                      type: "workflow.registry.reload.accepted",
                      data: %{
                        "workflow_id" => "registry_reload_by_id_flow",
                        "summary" => %{
                          "changed" => changed,
                          "total" => total
                        }
                      }
                    }},
                   5_000

    assert changed >= 1
    assert total >= 1
  end

  test "rejects workflow.registry.reload.requested for unknown workflow", context do
    assert {:ok, _published} =
             Bus.publish(context.bus, [
               Signal.new!(
                 "workflow.registry.reload.requested",
                 %{"workflow_id" => "missing_reload_flow"},
                 source: "/test/client"
               )
             ])

    assert_receive {:signal,
                    %Signal{
                      type: "workflow.registry.reload.rejected",
                      data: %{
                        "workflow_id" => "missing_reload_flow",
                        "reason" => reason
                      }
                    }},
                   5_000

    assert String.contains?(reason, "not_found")
  end

  test "normalizes workflow_id in workflow.registry.reload.rejected payloads", context do
    assert {:ok, _published} =
             Bus.publish(context.bus, [
               Signal.new!(
                 "workflow.registry.reload.requested",
                 %{"workflow_id" => "  missing_reload_flow  "},
                 source: "/test/client"
               )
             ])

    assert_receive {:signal,
                    %Signal{
                      type: "workflow.registry.reload.rejected",
                      data: %{"workflow_id" => "missing_reload_flow", "reason" => reason}
                    }},
                   5_000

    assert String.contains?(reason, "not_found")
  end

  test "echoes normalized id fallback in workflow.registry.reload.rejected payloads", context do
    assert {:ok, _published} =
             Bus.publish(context.bus, [
               Signal.new!(
                 "workflow.registry.reload.requested",
                 %{"id" => "  missing_reload_by_id_flow  "},
                 source: "/test/client"
               )
             ])

    assert_receive {:signal,
                    %Signal{
                      type: "workflow.registry.reload.rejected",
                      data: %{"workflow_id" => "missing_reload_by_id_flow", "reason" => reason}
                    }},
                   5_000

    assert String.contains?(reason, "not_found")
  end

  test "handles workflow.trigger.refresh.requested via trigger runtime", context do
    write_trigger_workflow(context.tmp_dir, "trigger_refresh_flow")
    assert {:ok, _summary} = WorkflowRegistry.refresh(context.workflow_registry)

    assert {:ok, _published} =
             Bus.publish(context.bus, [
               Signal.new!("workflow.trigger.refresh.requested", %{}, source: "/test/client")
             ])

    assert_receive {:signal,
                    %Signal{
                      type: "workflow.trigger.refresh.accepted",
                      data: %{
                        "summary" => %{
                          "registry" => %{},
                          "triggers" => %{"started" => started}
                        }
                      }
                    }},
                   5_000

    assert started >= 2
  end

  test "handles workflow.trigger.sync.requested via trigger runtime", context do
    write_trigger_workflow(context.tmp_dir, "trigger_sync_flow")
    assert {:ok, _summary} = WorkflowRegistry.refresh(context.workflow_registry)
    assert {:ok, %{triggers: _}} = TriggerRuntime.refresh(context.trigger_runtime)

    assert {:ok, _published} =
             Bus.publish(context.bus, [
               Signal.new!("workflow.trigger.sync.requested", %{}, source: "/test/client")
             ])

    assert_receive {:signal,
                    %Signal{
                      type: "workflow.trigger.sync.accepted",
                      data: %{
                        "summary" => %{"started" => 0, "skipped" => skipped}
                      }
                    }},
                   5_000

    assert skipped >= 1
  end

  test "returns trigger runtime status for workflow.trigger.runtime.status.requested", context do
    assert {:ok, _published} =
             Bus.publish(context.bus, [
               Signal.new!(
                 "workflow.trigger.runtime.status.requested",
                 %{},
                 source: "/test/client"
               )
             ])

    assert_receive {:signal,
                    %Signal{
                      type: "workflow.trigger.runtime.status.accepted",
                      data: %{
                        "status" => %{
                          "trigger_supervisor" => _trigger_supervisor,
                          "process_registry" => _process_registry,
                          "bus" => _bus
                        }
                      }
                    }},
                   5_000
  end

  test "rejects workflow.trigger.refresh.requested when trigger runtime is unavailable",
       context do
    GenServer.stop(context.trigger_runtime, :normal)

    assert {:ok, _published} =
             Bus.publish(context.bus, [
               Signal.new!("workflow.trigger.refresh.requested", %{}, source: "/test/client")
             ])

    assert_receive {:signal,
                    %Signal{
                      type: "workflow.trigger.refresh.rejected",
                      data: %{"reason" => reason}
                    }},
                   5_000

    assert String.contains?(reason, "trigger_runtime_unavailable")
  end

  test "handles workflow.trigger.manual.requested by trigger_id", context do
    write_workflow(context.tmp_dir, "command_flow")
    assert {:ok, _summary} = WorkflowRegistry.refresh(context.workflow_registry)

    trigger_id =
      start_manual_trigger(context,
        workflow_id: "command_flow",
        command: "/workflow:command_flow"
      )

    assert {:ok, _published} =
             Bus.publish(context.bus, [
               Signal.new!(
                 "workflow.trigger.manual.requested",
                 %{
                   "trigger_id" => trigger_id,
                   "params" => %{"value" => "from_manual_signal"}
                 },
                 source: "/test/client"
               )
             ])

    assert_receive {:signal,
                    %Signal{
                      type: "workflow.trigger.manual.accepted",
                      data: %{
                        "trigger_id" => ^trigger_id,
                        "workflow_id" => "command_flow",
                        "run_id" => run_id,
                        "status" => "completed"
                      }
                    }},
                   5_000

    assert is_binary(run_id)

    assert_receive {:signal,
                    %Signal{
                      type: "workflow.run.completed",
                      data: %{
                        "workflow_id" => "command_flow",
                        "run_id" => ^run_id,
                        "result" => %{"echo" => "from_manual_signal"}
                      }
                    }},
                   5_000
  end

  test "handles workflow.trigger.manual.requested by command with workflow disambiguation",
       context do
    write_workflow(context.tmp_dir, "command_flow")
    write_workflow(context.tmp_dir, "command_flow_alt")
    assert {:ok, _summary} = WorkflowRegistry.refresh(context.workflow_registry)

    _first_trigger_id =
      start_manual_trigger(context,
        workflow_id: "command_flow",
        command: "/workflow:review"
      )

    second_trigger_id =
      start_manual_trigger(context,
        workflow_id: "command_flow_alt",
        command: "/workflow:review"
      )

    assert {:ok, _published} =
             Bus.publish(context.bus, [
               Signal.new!(
                 "workflow.trigger.manual.requested",
                 %{
                   "workflow_id" => "command_flow_alt",
                   "command" => "/workflow:review",
                   "params" => %{"value" => "from_disambiguated_command"}
                 },
                 source: "/test/client"
               )
             ])

    assert_receive {:signal,
                    %Signal{
                      type: "workflow.trigger.manual.accepted",
                      data: %{
                        "trigger_id" => ^second_trigger_id,
                        "workflow_id" => "command_flow_alt",
                        "command" => "/workflow:review",
                        "run_id" => run_id,
                        "status" => "completed"
                      }
                    }},
                   5_000

    assert is_binary(run_id)

    assert_receive {:signal,
                    %Signal{
                      type: "workflow.run.completed",
                      data: %{
                        "workflow_id" => "command_flow_alt",
                        "run_id" => ^run_id,
                        "result" => %{"echo" => "from_disambiguated_command"}
                      }
                    }},
                   5_000
  end

  test "handles workflow.trigger.manual.requested by command with surrounding whitespace",
       context do
    write_workflow(context.tmp_dir, "command_flow")
    write_workflow(context.tmp_dir, "command_flow_alt")
    assert {:ok, _summary} = WorkflowRegistry.refresh(context.workflow_registry)

    _first_trigger_id =
      start_manual_trigger(context,
        workflow_id: "command_flow",
        command: "/workflow:review"
      )

    second_trigger_id =
      start_manual_trigger(context,
        workflow_id: "command_flow_alt",
        command: "/workflow:review"
      )

    assert {:ok, _published} =
             Bus.publish(context.bus, [
               Signal.new!(
                 "workflow.trigger.manual.requested",
                 %{
                   "workflow_id" => "  command_flow_alt  ",
                   "command" => "  /workflow:review  ",
                   "params" => %{"value" => "from_whitespace_wrapped_command"}
                 },
                 source: "/test/client"
               )
             ])

    assert_receive {:signal,
                    %Signal{
                      type: "workflow.trigger.manual.accepted",
                      data: %{
                        "trigger_id" => ^second_trigger_id,
                        "workflow_id" => "command_flow_alt",
                        "command" => "/workflow:review",
                        "run_id" => run_id,
                        "status" => "completed"
                      }
                    }},
                   5_000

    assert is_binary(run_id)

    assert_receive {:signal,
                    %Signal{
                      type: "workflow.run.completed",
                      data: %{
                        "workflow_id" => "command_flow_alt",
                        "run_id" => ^run_id,
                        "result" => %{"echo" => "from_whitespace_wrapped_command"}
                      }
                    }},
                   5_000
  end

  test "handles workflow.trigger.manual.requested by command with id fallback disambiguation",
       context do
    write_workflow(context.tmp_dir, "command_flow")
    write_workflow(context.tmp_dir, "command_flow_alt")
    assert {:ok, _summary} = WorkflowRegistry.refresh(context.workflow_registry)

    _first_trigger_id =
      start_manual_trigger(context,
        workflow_id: "command_flow",
        command: "/workflow:review"
      )

    second_trigger_id =
      start_manual_trigger(context,
        workflow_id: "command_flow_alt",
        command: "/workflow:review"
      )

    assert {:ok, _published} =
             Bus.publish(context.bus, [
               Signal.new!(
                 "workflow.trigger.manual.requested",
                 %{
                   "id" => "  command_flow_alt  ",
                   "command" => "  /workflow:review  ",
                   "params" => %{"value" => "from_id_fallback_disambiguation"}
                 },
                 source: "/test/client"
               )
             ])

    assert_receive {:signal,
                    %Signal{
                      type: "workflow.trigger.manual.accepted",
                      data: %{
                        "trigger_id" => ^second_trigger_id,
                        "workflow_id" => "command_flow_alt",
                        "command" => "/workflow:review",
                        "run_id" => run_id,
                        "status" => "completed"
                      }
                    }},
                   5_000

    assert is_binary(run_id)

    assert_receive {:signal,
                    %Signal{
                      type: "workflow.run.completed",
                      data: %{
                        "workflow_id" => "command_flow_alt",
                        "run_id" => ^run_id,
                        "result" => %{"echo" => "from_id_fallback_disambiguation"}
                      }
                    }},
                   5_000
  end

  test "does not include id fallback key in implicit workflow.trigger.manual.requested params",
       context do
    write_id_probe_workflow(context.tmp_dir, "command_flow")
    write_id_probe_workflow(context.tmp_dir, "command_flow_alt")
    assert {:ok, _summary} = WorkflowRegistry.refresh(context.workflow_registry)

    _first_trigger_id =
      start_manual_trigger(context,
        workflow_id: "command_flow",
        command: "/workflow:review"
      )

    second_trigger_id =
      start_manual_trigger(context,
        workflow_id: "command_flow_alt",
        command: "/workflow:review"
      )

    assert {:ok, _published} =
             Bus.publish(context.bus, [
               Signal.new!(
                 "workflow.trigger.manual.requested",
                 %{
                   "id" => "  command_flow_alt  ",
                   "command" => "  /workflow:review  ",
                   "value" => "from_implicit_id_params"
                 },
                 source: "/test/client"
               )
             ])

    assert_receive {:signal,
                    %Signal{
                      type: "workflow.trigger.manual.accepted",
                      data: %{
                        "trigger_id" => ^second_trigger_id,
                        "workflow_id" => "command_flow_alt",
                        "command" => "/workflow:review",
                        "run_id" => run_id,
                        "status" => "completed"
                      }
                    }},
                   5_000

    assert_receive {:signal,
                    %Signal{
                      type: "workflow.run.completed",
                      data: %{
                        "workflow_id" => "command_flow_alt",
                        "run_id" => ^run_id,
                        "result" => %{
                          "echo" => "from_implicit_id_params",
                          "id_seen" => nil
                        }
                      }
                    }},
                   5_000
  end

  test "rejects workflow.trigger.manual.requested when command resolves to multiple triggers",
       context do
    write_workflow(context.tmp_dir, "command_flow")
    write_workflow(context.tmp_dir, "command_flow_alt")
    assert {:ok, _summary} = WorkflowRegistry.refresh(context.workflow_registry)

    _first_trigger_id =
      start_manual_trigger(context,
        workflow_id: "command_flow",
        command: "/workflow:review"
      )

    _second_trigger_id =
      start_manual_trigger(context,
        workflow_id: "command_flow_alt",
        command: "/workflow:review"
      )

    assert {:ok, _published} =
             Bus.publish(context.bus, [
               Signal.new!(
                 "workflow.trigger.manual.requested",
                 %{
                   "command" => "/workflow:review",
                   "params" => %{"value" => "from_ambiguous_command"}
                 },
                 source: "/test/client"
               )
             ])

    assert_receive {:signal,
                    %Signal{
                      type: "workflow.trigger.manual.rejected",
                      data: %{
                        "command" => "/workflow:review",
                        "reason" => reason
                      }
                    }},
                   5_000

    assert String.contains?(reason, "ambiguous_manual_command")
  end

  test "echoes normalized id fallback in workflow.trigger.manual.rejected payloads", context do
    write_workflow(context.tmp_dir, "command_flow")
    write_workflow(context.tmp_dir, "command_flow_alt")
    assert {:ok, _summary} = WorkflowRegistry.refresh(context.workflow_registry)

    _first_trigger_id =
      start_manual_trigger(context,
        workflow_id: "command_flow",
        command: "/workflow:review"
      )

    _second_trigger_id =
      start_manual_trigger(context,
        workflow_id: "command_flow_alt",
        command: "/workflow:review"
      )

    assert {:ok, _published} =
             Bus.publish(context.bus, [
               Signal.new!(
                 "workflow.trigger.manual.requested",
                 %{
                   "id" => "  missing_workflow  ",
                   "command" => "  /workflow:review  ",
                   "params" => %{"value" => "from_missing_id_fallback"}
                 },
                 source: "/test/client"
               )
             ])

    assert_receive {:signal,
                    %Signal{
                      type: "workflow.trigger.manual.rejected",
                      data: %{
                        "workflow_id" => "missing_workflow",
                        "command" => "/workflow:review",
                        "reason" => reason
                      }
                    }},
                   5_000

    assert String.contains?(reason, "not_found")
  end

  test "normalizes command in workflow.trigger.manual.rejected payloads", context do
    write_workflow(context.tmp_dir, "command_flow")
    write_workflow(context.tmp_dir, "command_flow_alt")
    assert {:ok, _summary} = WorkflowRegistry.refresh(context.workflow_registry)

    _first_trigger_id =
      start_manual_trigger(context,
        workflow_id: "command_flow",
        command: "/workflow:review"
      )

    _second_trigger_id =
      start_manual_trigger(context,
        workflow_id: "command_flow_alt",
        command: "/workflow:review"
      )

    assert {:ok, _published} =
             Bus.publish(context.bus, [
               Signal.new!(
                 "workflow.trigger.manual.requested",
                 %{
                   "command" => "  /workflow:review  ",
                   "params" => %{"value" => "from_ambiguous_command_whitespace"}
                 },
                 source: "/test/client"
               )
             ])

    assert_receive {:signal,
                    %Signal{
                      type: "workflow.trigger.manual.rejected",
                      data: %{
                        "command" => "/workflow:review",
                        "reason" => reason
                      }
                    }},
                   5_000

    assert String.contains?(reason, "ambiguous_manual_command")
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

  test "stops in-flight run tasks when command runtime terminates", context do
    write_strategy_workflow(context.tmp_dir, "runtime_shutdown_flow")
    assert {:ok, _summary} = WorkflowRegistry.refresh(context.workflow_registry)

    run_id = "run_runtime_shutdown_1"

    assert {:ok, _published} =
             Bus.publish(context.bus, [
               Signal.new!(
                 "workflow.run.start.requested",
                 %{
                   "workflow_id" => "runtime_shutdown_flow",
                   "backend" => "direct",
                   "run_id" => run_id,
                   "inputs" => %{"value" => "hello", "delay_ms" => 2_000}
                 },
                 source: "/test/client"
               )
             ])

    assert_receive {:signal,
                    %Signal{
                      type: "workflow.run.start.accepted",
                      data: %{"workflow_id" => "runtime_shutdown_flow", "run_id" => ^run_id}
                    }},
                   5_000

    assert_receive {:signal,
                    %Signal{
                      type: "workflow.run.started",
                      data: %{"workflow_id" => "runtime_shutdown_flow", "run_id" => ^run_id}
                    }},
                   5_000

    assert_eventually(fn ->
      status = CommandRuntime.status(context.command_runtime)
      get_in(status, [:run_tasks, run_id, :task_alive?]) == true
    end)

    monitor_ref = Process.monitor(context.command_runtime)
    GenServer.stop(context.command_runtime, :normal)

    assert_receive {:DOWN, ^monitor_ref, :process, _pid, :normal}, 5_000

    refute_receive {:signal,
                    %Signal{
                      type: "workflow.run.completed",
                      data: %{"run_id" => ^run_id}
                    }},
                   2_500
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

  defp write_id_probe_workflow(dir, workflow_name) do
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
    - **module**: JidoWorkflow.Workflow.CommandRuntimeTestActions.EchoWithIdProbe
    - **inputs**:
      - value: `input:value`
      - id: `input:id`

    ## Return
    - **value**: echo
    """

    path = Path.join(dir, "#{workflow_name}.md")
    File.write!(path, markdown)
    path
  end

  defp write_disabled_workflow(dir, workflow_name) do
    markdown = """
    ---
    name: #{workflow_name}
    version: "1.0.0"
    enabled: false
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

  defp write_trigger_workflow(dir, workflow_name) do
    markdown = """
    ---
    name: #{workflow_name}
    version: "1.0.0"
    enabled: true
    triggers:
      - type: signal
        patterns: ["workflow.trigger.#{workflow_name}.requested"]
      - type: manual
        command: "/workflow:#{workflow_name}"
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

  defp start_manual_trigger(context, opts) do
    trigger_id = Keyword.get(opts, :trigger_id, "manual:#{System.unique_integer([:positive])}")
    workflow_id = Keyword.fetch!(opts, :workflow_id)
    command = Keyword.get(opts, :command)

    config = %{
      id: trigger_id,
      workflow_id: workflow_id,
      type: "manual",
      command: command,
      workflow_registry: context.workflow_registry,
      bus: context.bus,
      process_registry: context.trigger_process_registry
    }

    assert {:ok, _pid} =
             TriggerSupervisor.start_trigger(
               config,
               supervisor: context.trigger_supervisor,
               process_registry: context.trigger_process_registry
             )

    trigger_id
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
