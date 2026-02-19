defmodule JidoWorkflow.Workflow.HookRuntimeTestAdapter do
  @behaviour JidoWorkflow.Workflow.Hooks.Adapter

  @impl true
  def run(hook_name, payload) do
    case get_in(payload, ["data", "notify_pid"]) do
      pid when is_pid(pid) ->
        send(pid, {:runtime_hook, hook_name, payload})

      _other ->
        :ok
    end

    :ok
  end
end

defmodule JidoWorkflow.Workflow.HookRuntimeTest do
  use ExUnit.Case, async: true

  alias Jido.Signal
  alias Jido.Signal.Bus
  alias JidoWorkflow.Workflow.HookRuntime
  alias JidoWorkflow.Workflow.HooksIntegration

  test "runtime subscribes to workflow lifecycle signals and emits hooks" do
    bus = unique_name("hook_runtime_bus")
    runtime_name = unique_name("hook_runtime")

    start_supervised!({Bus, name: bus})

    runtime =
      start_supervised!(
        {HookRuntime,
         name: runtime_name, bus: bus, adapter: JidoWorkflow.Workflow.HookRuntimeTestAdapter}
      )

    assert {:ok, _published} =
             Bus.publish(bus, [
               Signal.new!(
                 "workflow.step.started",
                 %{
                   "workflow_id" => "runtime_example",
                   "run_id" => "run_runtime_1",
                   "step" => %{"name" => "parse_file", "type" => "action"},
                   "notify_pid" => self()
                 },
                 source: "/runtime_test"
               )
             ])

    assert_receive {:runtime_hook, :before_workflow_step, payload}
    assert payload["event_type"] == "workflow.step.started"
    assert payload["workflow_id"] == "runtime_example"
    assert payload["run_id"] == "run_runtime_1"
    assert payload["signal_source"] == "/runtime_test"

    status = HookRuntime.status(runtime)
    assert status.bus == bus
    assert status.adapter == JidoWorkflow.Workflow.HookRuntimeTestAdapter
    assert status.subscription_count == length(HooksIntegration.supported_signal_types())
  end

  test "runtime ignores unsupported signals" do
    bus = unique_name("hook_runtime_bus")
    runtime_name = unique_name("hook_runtime")

    start_supervised!({Bus, name: bus})

    _runtime =
      start_supervised!(
        {HookRuntime,
         name: runtime_name, bus: bus, adapter: JidoWorkflow.Workflow.HookRuntimeTestAdapter}
      )

    assert {:ok, _published} =
             Bus.publish(bus, [
               Signal.new!(
                 "workflow.unknown.event",
                 %{
                   "workflow_id" => "runtime_example",
                   "notify_pid" => self()
                 },
                 source: "/runtime_test"
               )
             ])

    refute_receive {:runtime_hook, _hook_name, _payload}
  end

  defp unique_name(prefix) do
    :"#{prefix}_#{System.unique_integer([:positive])}"
  end
end
