defmodule JidoWorkflow.Workflow.Actions.ExecuteAgentStepTestActions.PrepareContext do
  use Jido.Action,
    name: "prepare_context",
    schema: [
      ast: [type: :string, required: true]
    ]

  @impl true
  def run(%{ast: ast}, _context) do
    {:ok, %{"context_id" => "ctx:#{ast}"}}
  end
end

defmodule JidoWorkflow.Workflow.Actions.ExecuteAgentStepTestActions.CodeReviewer do
  use Jido.Action,
    name: "code_reviewer",
    schema: [
      code: [type: :string, required: true],
      ast: [type: :string, required: true],
      context_id: [type: :string, required: true]
    ]

  @impl true
  def run(%{code: code, ast: ast, context_id: context_id}, _context) do
    {:ok,
     %{
       "summary" => "review:#{code}:#{ast}:#{context_id}",
       "context_id" => context_id,
       "has_auto_fixable" => true
     }}
  end
end

defmodule JidoWorkflow.Workflow.Actions.ExecuteAgentStepTestActions.AsyncReviewer do
  use Jido.Action,
    name: "async_reviewer",
    schema: [
      code: [type: :string, required: true]
    ]

  @impl true
  def run(%{code: code}, _context) do
    {:ok, %{"summary" => "async:#{code}"}}
  end
end

defmodule JidoWorkflow.Workflow.Actions.ExecuteAgentStepTestActions.SlowReviewer do
  use Jido.Action,
    name: "slow_reviewer",
    schema: []

  @impl true
  def run(_params, _context) do
    Process.sleep(50)
    {:ok, %{"summary" => "slow"}}
  end
end

defmodule JidoWorkflow.Workflow.Actions.ExecuteAgentStepTestActions.FailingReviewer do
  use Jido.Action,
    name: "failing_reviewer",
    schema: []

  @impl true
  def run(_params, _context) do
    {:error, :boom}
  end
end

defmodule JidoWorkflow.Workflow.Actions.ExecuteAgentStepTestActions.FormatReviewOutput do
  use Jido.Action,
    name: "format_review_output",
    schema: [
      review: [type: :any, required: true]
    ]

  @impl true
  def run(%{review: review}, _context) do
    summary = Map.get(review, "summary") || Map.get(review, :summary)
    {:ok, %{"summary" => "formatted:#{summary}"}}
  end
end

defmodule JidoWorkflow.Workflow.Actions.ExecuteAgentStepTest do
  use ExUnit.Case, async: true

  alias Jido.Signal
  alias Jido.Signal.Bus
  alias JidoWorkflow.Workflow.Actions.ExecuteAgentStep

  test "executes pre-actions, agent, and post-actions for sync mode" do
    step = %{
      "name" => "ai_code_review",
      "agent" => "JidoWorkflow.Workflow.Actions.ExecuteAgentStepTestActions.CodeReviewer",
      "mode" => "sync",
      "inputs" => %{
        "code" => "`input:file_path`",
        "ast" => "`result:parse_file.ast`"
      },
      "pre_actions" => [
        %{
          "module" => "JidoWorkflow.Workflow.Actions.ExecuteAgentStepTestActions.PrepareContext",
          "inputs" => %{"ast" => "`result:parse_file.ast`"}
        }
      ],
      "post_actions" => [
        %{
          "module" =>
            "JidoWorkflow.Workflow.Actions.ExecuteAgentStepTestActions.FormatReviewOutput",
          "inputs" => %{"review" => "`result:ai_code_review`"}
        }
      ]
    }

    params = %{
      step: step,
      input: [
        %{
          "inputs" => %{"file_path" => "lib/example.ex"},
          "results" => %{"parse_file" => %{"ast" => "ast:lib/example.ex"}}
        }
      ]
    }

    assert {:ok, state} = ExecuteAgentStep.run(params, %{})

    assert state["results"]["ai_code_review"]["summary"] ==
             "formatted:review:lib/example.ex:ast:lib/example.ex:ctx:ast:lib/example.ex"

    assert state["results"]["ai_code_review"]["context_id"] == "ctx:ast:lib/example.ex"
    assert state["results"]["ai_code_review"]["has_auto_fixable"] == true
  end

  test "executes agent with async mode" do
    step = %{
      "name" => "security_scan",
      "agent" => "JidoWorkflow.Workflow.Actions.ExecuteAgentStepTestActions.AsyncReviewer",
      "mode" => "async",
      "inputs" => %{"code" => "`input:file_path`"}
    }

    params = %{step: step, file_path: "lib/example.ex"}

    assert {:ok, state} = ExecuteAgentStep.run(params, %{})
    assert state["results"]["security_scan"]["summary"] == "async:lib/example.ex"
  end

  test "returns timeout error when async agent exceeds timeout" do
    step = %{
      "name" => "security_scan",
      "agent" => "JidoWorkflow.Workflow.Actions.ExecuteAgentStepTestActions.SlowReviewer",
      "mode" => "async",
      "timeout_ms" => 10,
      "inputs" => %{}
    }

    assert {:error, {:agent_timeout, _, 10}} = ExecuteAgentStep.run(%{step: step}, %{})
  end

  test "publishes callback signal when callback_signal is configured" do
    callback_signal = "workflow.agent.callback.#{System.unique_integer([:positive])}"
    bus = start_test_bus()

    assert {:ok, _sub_id} =
             Bus.subscribe(bus, callback_signal, dispatch: {:pid, target: self()})

    step = %{
      "name" => "security_scan",
      "agent" => "JidoWorkflow.Workflow.Actions.ExecuteAgentStepTestActions.AsyncReviewer",
      "mode" => "async",
      "callback_signal" => callback_signal,
      "inputs" => %{"code" => "`input:file_path`"}
    }

    params = %{
      "inputs" => %{
        "file_path" => "lib/example.ex",
        "__workflow" =>
          workflow_context(bus, ["step_started", "step_completed", "step_failed", "agent_state"])
      },
      "results" => %{},
      step: step
    }

    assert {:ok, _state} = ExecuteAgentStep.run(params, %{})

    assert_receive {:signal,
                    %Signal{
                      type: ^callback_signal,
                      data: %{
                        "step_name" => "security_scan",
                        "agent" =>
                          "JidoWorkflow.Workflow.Actions.ExecuteAgentStepTestActions.AsyncReviewer",
                        "mode" => "async",
                        "result" => %{"summary" => "async:lib/example.ex"}
                      }
                    }}
  end

  test "returns error when callback_signal is invalid" do
    step = %{
      "name" => "security_scan",
      "agent" => "JidoWorkflow.Workflow.Actions.ExecuteAgentStepTestActions.AsyncReviewer",
      "mode" => "async",
      "callback_signal" => 123,
      "inputs" => %{"code" => "`input:file_path`"}
    }

    assert {:error, {:invalid_callback_signal, 123}} =
             ExecuteAgentStep.run(%{step: step, file_path: "lib/example.ex"}, %{})
  end

  test "returns mapped error when agent module is not available" do
    step = %{
      "name" => "security_scan",
      "agent" => "Nope.MissingAgent",
      "mode" => "sync",
      "inputs" => %{}
    }

    assert {:error, {:agent_not_loaded, "Nope.MissingAgent"}} =
             ExecuteAgentStep.run(%{step: step}, %{})
  end

  test "broadcasts step and agent state signals when workflow context is present" do
    bus = start_test_bus()

    assert {:ok, _sub_id} =
             Bus.subscribe(bus, "workflow.step.*", dispatch: {:pid, target: self()})

    assert {:ok, _sub_id} =
             Bus.subscribe(bus, "workflow.agent.state", dispatch: {:pid, target: self()})

    step = %{
      "name" => "security_scan",
      "type" => "agent",
      "agent" => "JidoWorkflow.Workflow.Actions.ExecuteAgentStepTestActions.AsyncReviewer",
      "mode" => "async",
      "inputs" => %{"code" => "`input:file_path`"}
    }

    params = %{
      "inputs" => %{
        "file_path" => "lib/example.ex",
        "__workflow" =>
          workflow_context(bus, ["step_started", "step_completed", "step_failed", "agent_state"])
      },
      "results" => %{},
      step: step
    }

    assert {:ok, _state} = ExecuteAgentStep.run(params, %{})

    assert_receive {:signal, %Signal{type: "workflow.step.started"}}

    assert_receive {:signal,
                    %Signal{
                      type: "workflow.agent.state",
                      data: %{"state" => %{"state" => "running"}}
                    }}

    assert_receive {:signal, %Signal{type: "workflow.step.completed"}}

    assert_receive {:signal,
                    %Signal{
                      type: "workflow.agent.state",
                      data: %{"state" => %{"state" => "completed"}}
                    }}
  end

  test "suppresses agent state signal when policy excludes agent_state" do
    bus = start_test_bus()

    assert {:ok, _sub_id} =
             Bus.subscribe(bus, "workflow.agent.state", dispatch: {:pid, target: self()})

    step = %{
      "name" => "security_scan",
      "type" => "agent",
      "agent" => "JidoWorkflow.Workflow.Actions.ExecuteAgentStepTestActions.FailingReviewer",
      "mode" => "sync",
      "inputs" => %{}
    }

    params = %{
      "inputs" => %{
        "__workflow" => workflow_context(bus, ["step_started", "step_failed"])
      },
      "results" => %{},
      step: step
    }

    assert {:error, {:agent_failed, _, _}} = ExecuteAgentStep.run(params, %{})
    refute_receive {:signal, %Signal{type: "workflow.agent.state"}}
  end

  defp workflow_context(bus, events) do
    %{
      "workflow_id" => "agent_test_workflow",
      "run_id" => "run_agent_1",
      "bus" => bus,
      "source" => "/jido_workflow/workflow/workflow%3Aagent_test",
      "publish_events" => events
    }
  end

  defp start_test_bus do
    bus = String.to_atom("jido_workflow_agent_test_bus_#{System.unique_integer([:positive])}")
    start_supervised!({Bus, name: bus})
    bus
  end
end
