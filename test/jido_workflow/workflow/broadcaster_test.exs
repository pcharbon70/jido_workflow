defmodule JidoWorkflow.Workflow.BroadcasterTest do
  use ExUnit.Case, async: true

  alias Jido.Signal
  alias Jido.Signal.Bus
  alias JidoWorkflow.Workflow.Broadcaster

  test "broadcasts workflow started signal" do
    bus = start_test_bus()

    assert {:ok, _sub_id} =
             Bus.subscribe(bus, "workflow.run.*", dispatch: {:pid, target: self()})

    assert {:ok, [_recorded]} =
             Broadcaster.broadcast_workflow_started("code_review", "run_1", %{"a" => 1}, bus: bus)

    assert_receive {:signal,
                    %Signal{
                      type: "workflow.run.started",
                      data: %{"workflow_id" => "code_review", "run_id" => "run_1"}
                    }}
  end

  test "broadcasts workflow completed signal" do
    bus = start_test_bus()

    assert {:ok, _sub_id} =
             Bus.subscribe(bus, "workflow.run.*", dispatch: {:pid, target: self()})

    result = %{"summary" => "ok"}

    assert {:ok, [_recorded]} =
             Broadcaster.broadcast_workflow_completed("code_review", "run_2", result, bus: bus)

    assert_receive {:signal,
                    %Signal{
                      type: "workflow.run.completed",
                      data: %{
                        "workflow_id" => "code_review",
                        "run_id" => "run_2",
                        "result" => ^result
                      }
                    }}
  end

  test "broadcasts workflow failed signal" do
    bus = start_test_bus()

    assert {:ok, _sub_id} =
             Bus.subscribe(bus, "workflow.run.*", dispatch: {:pid, target: self()})

    assert {:ok, [_recorded]} =
             Broadcaster.broadcast_workflow_failed("code_review", "run_3", :boom, bus: bus)

    assert_receive {:signal,
                    %Signal{
                      type: "workflow.run.failed",
                      data: %{
                        "workflow_id" => "code_review",
                        "run_id" => "run_3",
                        "reason" => "boom"
                      }
                    }}
  end

  defp start_test_bus do
    bus = String.to_atom("jido_workflow_test_bus_#{System.unique_integer([:positive])}")
    start_supervised!({Bus, name: bus})
    bus
  end
end
