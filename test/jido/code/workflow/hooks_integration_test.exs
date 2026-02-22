defmodule Jido.Code.Workflow.HooksIntegrationTestAdapter do
  @behaviour Jido.Code.Workflow.Hooks.Adapter

  @impl true
  def run(hook_name, payload) do
    case get_in(payload, ["data", "notify_pid"]) do
      pid when is_pid(pid) ->
        send(pid, {:workflow_hook, hook_name, payload})

      _other ->
        :ok
    end

    :ok
  end
end

defmodule Jido.Code.Workflow.HooksIntegrationTest do
  use ExUnit.Case, async: true

  alias Jido.Code.Workflow.HooksIntegration
  alias Jido.Signal

  test "emit_signal_hook/2 maps workflow.run.started to before_workflow" do
    signal =
      Signal.new!(
        "workflow.run.started",
        %{
          "workflow_id" => "example",
          "run_id" => "run_1",
          "notify_pid" => self()
        },
        source: "/test"
      )

    assert :ok =
             HooksIntegration.emit_signal_hook(
               signal,
               adapter: Jido.Code.Workflow.HooksIntegrationTestAdapter
             )

    assert_receive {:workflow_hook, :before_workflow, payload}
    assert payload["event_type"] == "workflow.run.started"
    assert payload["workflow_id"] == "example"
    assert payload["run_id"] == "run_1"
    assert payload["signal_source"] == "/test"
  end

  test "emit_signal_hook/2 maps step completion/failure to after_workflow_step" do
    step_completed_signal =
      Signal.new!(
        "workflow.step.completed",
        %{
          "workflow_id" => "example",
          "run_id" => "run_2",
          "step" => %{"name" => "parse_file", "type" => "action"},
          "status" => "completed",
          "notify_pid" => self()
        },
        source: "/test"
      )

    assert :ok =
             HooksIntegration.emit_signal_hook(
               step_completed_signal,
               adapter: Jido.Code.Workflow.HooksIntegrationTestAdapter
             )

    assert_receive {:workflow_hook, :after_workflow_step, completed_payload}
    assert completed_payload["status"] == "completed"
    assert completed_payload["step"] == %{"name" => "parse_file", "type" => "action"}

    step_failed_signal =
      Signal.new!(
        "workflow.step.failed",
        %{
          "workflow_id" => "example",
          "run_id" => "run_2",
          "step" => %{"name" => "parse_file", "type" => "action"},
          "status" => "failed",
          "reason" => "boom",
          "notify_pid" => self()
        },
        source: "/test"
      )

    assert :ok =
             HooksIntegration.emit_signal_hook(
               step_failed_signal,
               adapter: Jido.Code.Workflow.HooksIntegrationTestAdapter
             )

    assert_receive {:workflow_hook, :after_workflow_step, failed_payload}
    assert failed_payload["status"] == "failed"
    assert failed_payload["reason"] == "boom"
  end

  test "emit_signal_hook/2 ignores unsupported signals" do
    signal =
      Signal.new!(
        "workflow.custom.unhandled",
        %{
          "workflow_id" => "example",
          "notify_pid" => self()
        },
        source: "/test"
      )

    assert :ok =
             HooksIntegration.emit_signal_hook(
               signal,
               adapter: Jido.Code.Workflow.HooksIntegrationTestAdapter
             )

    refute_receive {:workflow_hook, _hook_name, _payload}
  end
end
