defmodule JidoWorkflow.TestActions.ParseFile do
  use Jido.Action,
    name: "parse_file",
    schema: [
      file_path: [type: :string, required: true]
    ]

  @impl true
  def run(%{file_path: file_path}, _context) do
    {:ok, %{"ast" => "ast:#{file_path}", "has_auto_fixable" => true}}
  end
end

defmodule JidoWorkflow.TestActions.BuildSummary do
  use Jido.Action,
    name: "build_summary",
    schema: [
      ast: [type: :string, required: true]
    ]

  @impl true
  def run(%{ast: ast}, _context) do
    {:ok, %{"summary" => "summary:#{ast}"}}
  end
end

defmodule JidoWorkflow.TestActions.FailAction do
  use Jido.Action,
    name: "fail_action",
    schema: []

  @impl true
  def run(_params, _context) do
    {:error, :boom}
  end
end

defmodule JidoWorkflow.Workflow.Actions.ExecuteActionStepTest do
  use ExUnit.Case, async: true

  alias Jido.Signal
  alias Jido.Signal.Bus
  alias JidoWorkflow.Workflow.Actions.ExecuteActionStep

  test "executes configured action module with resolved input references" do
    step = %{
      "name" => "parse_file",
      "module" => "JidoWorkflow.TestActions.ParseFile",
      "inputs" => %{"file_path" => "`input:file_path`"}
    }

    params = %{step: step, file_path: "lib/example.ex"}

    assert {:ok, state} = ExecuteActionStep.run(params, %{})
    assert state["inputs"]["file_path"] == "lib/example.ex"
    assert state["results"]["parse_file"]["ast"] == "ast:lib/example.ex"
  end

  test "resolves result references from prior step outputs" do
    step = %{
      "name" => "build_summary",
      "module" => "JidoWorkflow.TestActions.BuildSummary",
      "inputs" => %{"ast" => "`result:parse_file.ast`"}
    }

    params = %{
      "inputs" => %{"file_path" => "lib/example.ex"},
      "results" => %{"parse_file" => %{"ast" => "ast:lib/example.ex"}},
      step: step
    }

    assert {:ok, state} = ExecuteActionStep.run(params, %{})
    assert state["results"]["build_summary"]["summary"] == "summary:ast:lib/example.ex"
  end

  test "resolves state from runic :input payload format" do
    step = %{
      "name" => "build_summary",
      "module" => "JidoWorkflow.TestActions.BuildSummary",
      "inputs" => %{"ast" => "`result:parse_file.ast`"}
    }

    params = %{
      input: [
        %{
          "inputs" => %{"file_path" => "lib/example.ex"},
          "results" => %{"parse_file" => %{"ast" => "ast:lib/example.ex"}}
        }
      ],
      step: step
    }

    assert {:ok, state} = ExecuteActionStep.run(params, %{})
    assert state["results"]["build_summary"]["summary"] == "summary:ast:lib/example.ex"
  end

  test "returns error when target module is not loaded" do
    step = %{"name" => "missing", "module" => "Nope.Module", "inputs" => %{}}

    assert {:error, {:module_not_loaded, "Nope.Module"}} =
             ExecuteActionStep.run(%{step: step}, %{})
  end

  test "broadcasts step started and completed signals when workflow context is present" do
    bus = start_test_bus()

    assert {:ok, _sub_id} =
             Bus.subscribe(bus, "workflow.step.*", dispatch: {:pid, target: self()})

    step = %{
      "name" => "parse_file",
      "type" => "action",
      "module" => "JidoWorkflow.TestActions.ParseFile",
      "inputs" => %{"file_path" => "`input:file_path`"}
    }

    params = %{
      "inputs" => %{
        "file_path" => "lib/example.ex",
        "__workflow" => workflow_context(bus, ["step_started", "step_completed"])
      },
      "results" => %{},
      step: step
    }

    assert {:ok, _state} = ExecuteActionStep.run(params, %{})

    assert_receive {:signal,
                    %Signal{
                      type: "workflow.step.started",
                      data: %{
                        "workflow_id" => "action_test_workflow",
                        "run_id" => "run_action_1",
                        "step" => %{"name" => "parse_file", "type" => "action"}
                      }
                    }}

    assert_receive {:signal,
                    %Signal{
                      type: "workflow.step.completed",
                      data: %{
                        "workflow_id" => "action_test_workflow",
                        "run_id" => "run_action_1",
                        "step" => %{"name" => "parse_file", "type" => "action"},
                        "status" => "completed"
                      }
                    }}
  end

  test "suppresses step failed broadcast when publish policy excludes step_failed" do
    bus = start_test_bus()

    assert {:ok, _sub_id} =
             Bus.subscribe(bus, "workflow.step.*", dispatch: {:pid, target: self()})

    step = %{
      "name" => "fail_step",
      "type" => "action",
      "module" => "JidoWorkflow.TestActions.FailAction",
      "inputs" => %{}
    }

    params = %{
      "inputs" => %{
        "__workflow" => workflow_context(bus, ["step_started"])
      },
      "results" => %{},
      step: step
    }

    assert {:error, {:action_failed, _reason}} = ExecuteActionStep.run(params, %{})

    assert_receive {:signal, %Signal{type: "workflow.step.started"}}
    refute_receive {:signal, %Signal{type: "workflow.step.failed"}}
  end

  test "prefers publish_events over legacy broadcast_events when both are provided" do
    bus = start_test_bus()

    assert {:ok, _sub_id} =
             Bus.subscribe(bus, "workflow.step.*", dispatch: {:pid, target: self()})

    step = %{
      "name" => "fail_step",
      "type" => "action",
      "module" => "JidoWorkflow.TestActions.FailAction",
      "inputs" => %{}
    }

    params = %{
      "inputs" => %{
        "__workflow" =>
          workflow_context(bus, ["step_started"],
            broadcast_events: ["step_started", "step_failed"]
          )
      },
      "results" => %{},
      step: step
    }

    assert {:error, {:action_failed, _reason}} = ExecuteActionStep.run(params, %{})

    assert_receive {:signal, %Signal{type: "workflow.step.started"}}
    refute_receive {:signal, %Signal{type: "workflow.step.failed"}}
  end

  test "falls back to legacy broadcast_events when publish_events is not present" do
    bus = start_test_bus()

    assert {:ok, _sub_id} =
             Bus.subscribe(bus, "workflow.step.*", dispatch: {:pid, target: self()})

    step = %{
      "name" => "fail_step",
      "type" => "action",
      "module" => "JidoWorkflow.TestActions.FailAction",
      "inputs" => %{}
    }

    params = %{
      "inputs" => %{
        "__workflow" => workflow_context_without_publish(bus, ["step_started", "step_failed"])
      },
      "results" => %{},
      step: step
    }

    assert {:error, {:action_failed, _reason}} = ExecuteActionStep.run(params, %{})

    assert_receive {:signal, %Signal{type: "workflow.step.started"}}
    assert_receive {:signal, %Signal{type: "workflow.step.failed"}}
  end

  defp workflow_context(bus, events, opts \\ []) do
    %{
      "workflow_id" => "action_test_workflow",
      "run_id" => "run_action_1",
      "bus" => bus,
      "source" => "/jido_workflow/workflow/workflow%3Aaction_test",
      "publish_events" => events
    }
    |> maybe_put_broadcast_events(Keyword.get(opts, :broadcast_events))
  end

  defp workflow_context_without_publish(bus, broadcast_events) do
    %{
      "workflow_id" => "action_test_workflow",
      "run_id" => "run_action_1",
      "bus" => bus,
      "source" => "/jido_workflow/workflow/workflow%3Aaction_test",
      "broadcast_events" => broadcast_events
    }
  end

  defp maybe_put_broadcast_events(context, nil), do: context

  defp maybe_put_broadcast_events(context, events),
    do: Map.put(context, "broadcast_events", events)

  defp start_test_bus do
    bus = String.to_atom("jido_workflow_action_test_bus_#{System.unique_integer([:positive])}")
    start_supervised!({Bus, name: bus})
    bus
  end
end
