defmodule Jido.Code.Workflow.MixTasks.WorkflowRunTestActions.Echo do
  use Jido.Action,
    name: "mix_task_workflow_run_echo",
    schema: [
      value: [type: :string, required: true]
    ]

  @impl true
  def run(%{value: value}, _context) do
    {:ok, %{"echo" => value}}
  end
end

defmodule Jido.Code.Workflow.MixTasks.WorkflowRunTestActions.DelayedEcho do
  use Jido.Action,
    name: "mix_task_workflow_run_delayed_echo",
    schema: [
      value: [type: :string, required: true],
      delay_ms: [type: :integer, required: false, default: 250]
    ]

  @impl true
  def run(%{value: value, delay_ms: delay_ms}, _context) do
    Process.sleep(delay_ms)
    {:ok, %{"echo" => value}}
  end
end

defmodule Mix.Tasks.Workflow.RunTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Jido.Code.Workflow.CommandRuntime
  alias Jido.Code.Workflow.Registry, as: WorkflowRegistry
  alias Jido.Code.Workflow.RunStore
  alias Jido.Code.Workflow.TriggerRuntime
  alias Jido.Code.Workflow.TriggerSupervisor
  alias Jido.Signal
  alias Jido.Signal.Bus
  alias Mix.Tasks.Workflow.Run

  setup do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "jido_workflow_mix_task_run_test_#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(tmp_dir)
    File.mkdir_p!(tmp_dir)

    completed_workflow_id = "task_run_completed_flow"
    delayed_workflow_id = "task_run_delayed_flow"

    write_completed_workflow(tmp_dir, completed_workflow_id)
    write_delayed_workflow(tmp_dir, delayed_workflow_id)

    bus = unique_name("mix_task_run_bus")
    start_supervised!({Bus, name: bus})

    workflow_registry_name = unique_name("mix_task_run_registry")

    workflow_registry =
      start_supervised!({WorkflowRegistry, workflow_dir: tmp_dir, name: workflow_registry_name})

    run_store = unique_name("mix_task_run_store")
    start_supervised!({RunStore, name: run_store})

    trigger_process_registry = unique_name("mix_task_run_trigger_process_registry")
    start_supervised!({Registry, keys: :unique, name: trigger_process_registry})

    trigger_supervisor = unique_name("mix_task_run_trigger_supervisor")
    start_supervised!({TriggerSupervisor, name: trigger_supervisor})

    trigger_runtime_name = unique_name("mix_task_run_trigger_runtime")

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

    command_runtime = unique_name("mix_task_run_command_runtime")

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

    on_exit(fn ->
      Mix.Task.reenable("workflow.run")
      File.rm_rf!(tmp_dir)
    end)

    {:ok,
     bus: bus,
     run_store: run_store,
     completed_workflow_id: completed_workflow_id,
     delayed_workflow_id: delayed_workflow_id}
  end

  test "starts workflow and waits for completion by default", context do
    output =
      capture_io(fn ->
        Run.run([
          context.completed_workflow_id,
          "--no-start-app",
          "--no-pretty",
          "--bus",
          Atom.to_string(context.bus),
          "--inputs",
          ~s({"value":"hello"})
        ])
      end)

    payload = Jason.decode!(output)

    assert payload["status"] == "completed"
    assert payload["workflow_id"] == context.completed_workflow_id
    assert is_binary(payload["run_id"])
    assert get_in(payload, ["terminal_signal", "type"]) == "workflow.run.completed"
    assert get_in(payload, ["terminal_signal", "data", "result"]) == %{"echo" => "hello"}

    assert {:ok, run} = RunStore.get(payload["run_id"], context.run_store)
    assert run.status == :completed
  end

  test "supports accepted-only mode with --no-await-completion", context do
    output =
      capture_io(fn ->
        Run.run([
          context.delayed_workflow_id,
          "--no-start-app",
          "--no-pretty",
          "--no-await-completion",
          "--bus",
          Atom.to_string(context.bus),
          "--inputs",
          ~s({"value":"slow","delay_ms":300})
        ])
      end)

    payload = Jason.decode!(output)
    run_id = payload["run_id"]

    assert payload["status"] == "accepted"
    assert payload["workflow_id"] == context.delayed_workflow_id
    assert is_binary(run_id)
    assert get_in(payload, ["start_response", "type"]) == "workflow.run.start.accepted"

    assert eventually_completed?(context.run_store, run_id, 2_000)
  end

  test "raises when start request is rejected", context do
    assert_raise Mix.Error, ~r/Run start rejected/, fn ->
      capture_io(fn ->
        Run.run([
          "missing_workflow",
          "--no-start-app",
          "--no-pretty",
          "--bus",
          Atom.to_string(context.bus),
          "--inputs",
          ~s({"value":"x"})
        ])
      end)
    end
  end

  test "ignores unrelated start accepted responses and matches by requested_signal_id" do
    isolated_bus = unique_name("mix_task_run_isolated_bus")
    start_supervised!({Bus, name: isolated_bus})
    start_run_start_responder(isolated_bus)
    assert_receive :run_start_responder_ready, 1_000

    output =
      capture_io(fn ->
        Run.run([
          "correlation_flow",
          "--no-start-app",
          "--no-pretty",
          "--no-await-completion",
          "--bus",
          Atom.to_string(isolated_bus),
          "--source",
          "/test/workflow.run/correlation",
          "--timeout",
          "1000",
          "--inputs",
          ~s({"value":"hello"})
        ])
      end)

    payload = Jason.decode!(output)
    request_id = get_in(payload, ["request", "id"])

    assert payload["status"] == "accepted"
    assert payload["workflow_id"] == "correlation_flow"
    assert payload["run_id"] == "run_correlated"
    assert get_in(payload, ["start_response", "type"]) == "workflow.run.start.accepted"
    assert get_in(payload, ["start_response", "data", "requested_signal_id"]) == request_id
    assert_receive :run_start_responder_done, 2_000
  end

  defp eventually_completed?(run_store, run_id, timeout_ms) do
    started_at = now_ms()
    do_eventually_completed?(run_store, run_id, timeout_ms, started_at)
  end

  defp do_eventually_completed?(run_store, run_id, timeout_ms, started_at) do
    case RunStore.get(run_id, run_store) do
      {:ok, %{status: :completed}} ->
        true

      _other ->
        if now_ms() - started_at >= timeout_ms do
          false
        else
          Process.sleep(25)
          do_eventually_completed?(run_store, run_id, timeout_ms, started_at)
        end
    end
  end

  defp write_completed_workflow(dir, workflow_name) do
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
    - **module**: Jido.Code.Workflow.MixTasks.WorkflowRunTestActions.Echo
    - **inputs**:
      - value: `input:value`

    ## Return
    - **value**: echo
    """

    path = Path.join(dir, "#{workflow_name}.md")
    File.write!(path, markdown)
    path
  end

  defp write_delayed_workflow(dir, workflow_name) do
    markdown = """
    ---
    name: #{workflow_name}
    version: "1.0.0"
    enabled: true
    ---

    # #{workflow_name}

    ## Steps

    ### delayed_echo
    - **type**: action
    - **module**: Jido.Code.Workflow.MixTasks.WorkflowRunTestActions.DelayedEcho
    - **inputs**:
      - value: `input:value`
      - delay_ms: `input:delay_ms`

    ## Return
    - **value**: delayed_echo
    """

    path = Path.join(dir, "#{workflow_name}.md")
    File.write!(path, markdown)
    path
  end

  defp unique_name(prefix) do
    :"#{prefix}_#{System.unique_integer([:positive])}"
  end

  defp start_run_start_responder(bus) do
    parent = self()

    spawn(fn ->
      assert {:ok, _subscription_id} =
               Bus.subscribe(bus, "workflow.run.start.requested",
                 dispatch: {:pid, target: self()}
               )

      send(parent, :run_start_responder_ready)

      receive do
        {:signal, %Signal{} = request_signal} ->
          workflow_id = get_in(request_signal.data, ["workflow_id"]) || "unknown_flow"

          # Publish noise first; the task should ignore this uncorrelated response.
          assert {:ok, _published} =
                   Bus.publish(bus, [
                     Signal.new!(
                       "workflow.run.start.accepted",
                       %{"workflow_id" => workflow_id, "run_id" => "run_noise"},
                       source: "/test/workflow.run/noise"
                     )
                   ])

          Process.sleep(25)

          assert {:ok, _published} =
                   Bus.publish(bus, [
                     Signal.new!(
                       "workflow.run.start.accepted",
                       %{
                         "workflow_id" => workflow_id,
                         "run_id" => "run_correlated",
                         "requested_signal_id" => request_signal.id,
                         "requested_signal_type" => request_signal.type,
                         "requested_signal_source" => request_signal.source
                       },
                       source: "/test/workflow.run/responder"
                     )
                   ])

          send(parent, :run_start_responder_done)
      end
    end)
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
