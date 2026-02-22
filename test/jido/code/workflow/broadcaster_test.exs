defmodule Jido.Code.Workflow.BroadcasterTest do
  use ExUnit.Case, async: true

  alias Jido.Code.Workflow.Broadcaster
  alias Jido.Signal
  alias Jido.Signal.Bus

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

  test "broadcasts workflow paused signal" do
    bus = start_test_bus()

    assert {:ok, _sub_id} =
             Bus.subscribe(bus, "workflow.run.*", dispatch: {:pid, target: self()})

    assert {:ok, [_recorded]} =
             Broadcaster.broadcast_workflow_paused(
               "code_review",
               "run_3a",
               %{"backend" => "direct"},
               bus: bus
             )

    assert_receive {:signal,
                    %Signal{
                      type: "workflow.run.paused",
                      data: %{
                        "workflow_id" => "code_review",
                        "run_id" => "run_3a",
                        "status" => "paused",
                        "metadata" => %{"backend" => "direct"}
                      }
                    }}
  end

  test "broadcasts workflow resumed signal" do
    bus = start_test_bus()

    assert {:ok, _sub_id} =
             Bus.subscribe(bus, "workflow.run.*", dispatch: {:pid, target: self()})

    assert {:ok, [_recorded]} =
             Broadcaster.broadcast_workflow_resumed(
               "code_review",
               "run_3b",
               %{"backend" => "strategy"},
               bus: bus
             )

    assert_receive {:signal,
                    %Signal{
                      type: "workflow.run.resumed",
                      data: %{
                        "workflow_id" => "code_review",
                        "run_id" => "run_3b",
                        "status" => "running",
                        "metadata" => %{"backend" => "strategy"}
                      }
                    }}
  end

  test "broadcasts workflow cancelled signal" do
    bus = start_test_bus()

    assert {:ok, _sub_id} =
             Bus.subscribe(bus, "workflow.run.*", dispatch: {:pid, target: self()})

    assert {:ok, [_recorded]} =
             Broadcaster.broadcast_workflow_cancelled(
               "code_review",
               "run_3c",
               :user_cancelled,
               bus: bus
             )

    assert_receive {:signal,
                    %Signal{
                      type: "workflow.run.cancelled",
                      data: %{
                        "workflow_id" => "code_review",
                        "run_id" => "run_3c",
                        "status" => "cancelled",
                        "reason" => "user_cancelled"
                      }
                    }}
  end

  test "broadcasts workflow step started signal" do
    bus = start_test_bus()

    assert {:ok, _sub_id} =
             Bus.subscribe(bus, "workflow.step.*", dispatch: {:pid, target: self()})

    step = %{"name" => "parse_file", "type" => "action"}

    assert {:ok, [_recorded]} =
             Broadcaster.broadcast_step_started("code_review", "run_4", step, bus: bus)

    assert_receive {:signal,
                    %Signal{
                      type: "workflow.step.started",
                      data: %{
                        "workflow_id" => "code_review",
                        "run_id" => "run_4",
                        "step" => %{"name" => "parse_file", "type" => "action"}
                      }
                    }}
  end

  test "broadcasts workflow step failed signal" do
    bus = start_test_bus()

    assert {:ok, _sub_id} =
             Bus.subscribe(bus, "workflow.step.*", dispatch: {:pid, target: self()})

    step = %{"name" => "ai_code_review", "type" => "agent"}

    assert {:ok, [_recorded]} =
             Broadcaster.broadcast_step_failed("code_review", "run_5", step, :boom, bus: bus)

    assert_receive {:signal,
                    %Signal{
                      type: "workflow.step.failed",
                      data: %{
                        "workflow_id" => "code_review",
                        "run_id" => "run_5",
                        "reason" => "boom",
                        "step" => %{"name" => "ai_code_review", "type" => "agent"}
                      }
                    }}
  end

  test "broadcasts workflow agent state signal" do
    bus = start_test_bus()

    assert {:ok, _sub_id} =
             Bus.subscribe(bus, "workflow.agent.state", dispatch: {:pid, target: self()})

    assert {:ok, [_recorded]} =
             Broadcaster.broadcast_agent_state(
               "code_review",
               "run_6",
               "code_reviewer",
               %{state: "running", step: %{name: "ai_code_review"}},
               bus: bus
             )

    assert_receive {:signal,
                    %Signal{
                      type: "workflow.agent.state",
                      data: %{
                        "workflow_id" => "code_review",
                        "run_id" => "run_6",
                        "agent" => "code_reviewer",
                        "state" => %{
                          "state" => "running",
                          "step" => %{"name" => "ai_code_review"}
                        }
                      }
                    }}
  end

  defp start_test_bus do
    bus = String.to_atom("jido_workflow_test_bus_#{System.unique_integer([:positive])}")
    start_supervised!({Bus, name: bus})
    bus
  end
end
