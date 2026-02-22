defmodule Jido.Code.Workflow.MixTasks.WorkflowSignalTestActions.Echo do
  use Jido.Action,
    name: "mix_task_workflow_signal_echo",
    schema: [
      value: [type: :string, required: true]
    ]

  @impl true
  def run(%{value: value}, _context) do
    {:ok, %{"echo" => value}}
  end
end

defmodule Mix.Tasks.Workflow.SignalTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Jido.Code.Workflow.CommandRuntime
  alias Jido.Code.Workflow.Registry, as: WorkflowRegistry
  alias Jido.Code.Workflow.RunStore
  alias Jido.Code.Workflow.TriggerRuntime
  alias Jido.Code.Workflow.TriggerSupervisor
  alias Jido.Signal
  alias Jido.Signal.Bus

  setup do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "jido_workflow_mix_task_signal_test_#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(tmp_dir)
    File.mkdir_p!(tmp_dir)

    workflow_id = "task_signal_flow"
    write_workflow(tmp_dir, workflow_id)

    bus = unique_name("mix_task_signal_bus")
    start_supervised!({Bus, name: bus})

    workflow_registry_name = unique_name("mix_task_signal_registry")

    workflow_registry =
      start_supervised!({WorkflowRegistry, workflow_dir: tmp_dir, name: workflow_registry_name})

    run_store = unique_name("mix_task_signal_run_store")
    start_supervised!({RunStore, name: run_store})

    trigger_process_registry = unique_name("mix_task_trigger_process_registry")
    start_supervised!({Registry, keys: :unique, name: trigger_process_registry})

    trigger_supervisor = unique_name("mix_task_trigger_supervisor")
    start_supervised!({TriggerSupervisor, name: trigger_supervisor})

    trigger_runtime_name = unique_name("mix_task_trigger_runtime")

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

    command_runtime = unique_name("mix_task_command_runtime")

    start_supervised!(
      {CommandRuntime,
       name: command_runtime,
       bus: bus,
       workflow_registry: workflow_registry,
       run_store: run_store,
       trigger_supervisor: trigger_supervisor,
       trigger_process_registry: trigger_process_registry,
       trigger_runtime: trigger_runtime}
    )

    assert {:ok, _summary} = WorkflowRegistry.refresh(workflow_registry)
    assert {:ok, _sub_id} = Bus.subscribe(bus, "workflow.run.*", dispatch: {:pid, target: self()})

    on_exit(fn ->
      Mix.Task.reenable("workflow.signal")
      File.rm_rf!(tmp_dir)
    end)

    {:ok, bus: bus, workflow_id: workflow_id, run_store: run_store}
  end

  test "publishes requested signal and waits for accepted response", context do
    Mix.Task.reenable("workflow.signal")
    workflow_id = context.workflow_id

    output =
      capture_io(fn ->
        Mix.Tasks.Workflow.Signal.run([
          "workflow.run.start.requested",
          "--no-start-app",
          "--no-pretty",
          "--bus",
          Atom.to_string(context.bus),
          "--source",
          "/test/workflow.signal",
          "--data",
          ~s({"workflow_id":"#{context.workflow_id}","inputs":{"value":"hello"}})
        ])
      end)

    payload = Jason.decode!(output)
    assert payload["status"] == "accepted"
    assert get_in(payload, ["response", "type"]) == "workflow.run.start.accepted"

    run_id = get_in(payload, ["response", "data", "run_id"])
    assert is_binary(run_id)

    assert_receive {:signal,
                    %Signal{
                      type: "workflow.run.completed",
                      data: %{
                        "workflow_id" => ^workflow_id,
                        "run_id" => ^run_id,
                        "result" => %{"echo" => "hello"}
                      }
                    }},
                   5_000

    assert {:ok, run} = RunStore.get(run_id, context.run_store)
    assert run.status == :completed
  end

  test "supports publish without waiting for response", context do
    Mix.Task.reenable("workflow.signal")
    workflow_id = context.workflow_id

    output =
      capture_io(fn ->
        Mix.Tasks.Workflow.Signal.run([
          "workflow.run.start.requested",
          "--no-start-app",
          "--no-pretty",
          "--no-wait",
          "--bus",
          Atom.to_string(context.bus),
          "--source",
          "/test/workflow.signal",
          "--data",
          ~s({"workflow_id":"#{context.workflow_id}","inputs":{"value":"async"}})
        ])
      end)

    payload = Jason.decode!(output)
    assert payload["status"] == "published"
    assert get_in(payload, ["request", "type"]) == "workflow.run.start.requested"

    assert_receive {:signal,
                    %Signal{
                      type: "workflow.run.completed",
                      data: %{
                        "workflow_id" => ^workflow_id,
                        "result" => %{"echo" => "async"}
                      }
                    }},
                   5_000
  end

  test "raises when command runtime rejects request", context do
    Mix.Task.reenable("workflow.signal")

    assert_raise Mix.Error, ~r/Signal rejected: workflow\.run\.start\.rejected/, fn ->
      capture_io(fn ->
        Mix.Tasks.Workflow.Signal.run([
          "workflow.run.start.requested",
          "--no-start-app",
          "--no-pretty",
          "--bus",
          Atom.to_string(context.bus),
          "--source",
          "/test/workflow.signal",
          "--data",
          ~s({"workflow_id":"missing_flow","inputs":{"value":"x"}})
        ])
      end)
    end
  end

  test "ignores unrelated accepted responses and matches by requested_signal_id" do
    Mix.Task.reenable("workflow.signal")

    isolated_bus = unique_name("mix_task_signal_isolated_bus")
    start_supervised!({Bus, name: isolated_bus})

    request_type = "workflow.test.echo.requested"
    accepted_type = "workflow.test.echo.accepted"
    start_request_responder(isolated_bus, request_type, accepted_type)
    assert_receive :request_responder_ready, 1_000

    output =
      capture_io(fn ->
        Mix.Tasks.Workflow.Signal.run([
          request_type,
          "--no-start-app",
          "--no-pretty",
          "--bus",
          Atom.to_string(isolated_bus),
          "--source",
          "/test/workflow.signal/correlation",
          "--timeout",
          "1000",
          "--data",
          ~s({"value":"correlated"})
        ])
      end)

    payload = Jason.decode!(output)
    request_id = get_in(payload, ["request", "id"])

    assert payload["status"] == "accepted"
    assert get_in(payload, ["response", "type"]) == accepted_type
    assert get_in(payload, ["response", "data", "requested_signal_id"]) == request_id
    assert get_in(payload, ["response", "data", "result"]) == "correlated"
    assert_receive :request_responder_done, 2_000
  end

  defp start_request_responder(bus, request_type, accepted_type) do
    parent = self()

    spawn(fn ->
      assert {:ok, _subscription_id} =
               Bus.subscribe(bus, request_type, dispatch: {:pid, target: self()})

      send(parent, :request_responder_ready)

      receive do
        {:signal, %Signal{} = request_signal} ->
          # Publish noise first; the task should ignore this uncorrelated response.
          assert {:ok, _published} =
                   Bus.publish(bus, [
                     Signal.new!(
                       accepted_type,
                       %{"result" => "noise"},
                       source: "/test/workflow.signal/noise"
                     )
                   ])

          Process.sleep(25)

          assert {:ok, _published} =
                   Bus.publish(bus, [
                     Signal.new!(
                       accepted_type,
                       %{
                         "requested_signal_id" => request_signal.id,
                         "requested_signal_type" => request_signal.type,
                         "requested_signal_source" => request_signal.source,
                         "result" => "correlated"
                       },
                       source: "/test/workflow.signal/responder"
                     )
                   ])

          send(parent, :request_responder_done)
      end
    end)
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
    - **module**: Jido.Code.Workflow.MixTasks.WorkflowSignalTestActions.Echo
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
