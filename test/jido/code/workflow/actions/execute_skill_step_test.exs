defmodule Jido.Code.Workflow.TestSkills.EchoSkill do
  def handle_workflow_step(inputs, state) do
    file_path = Map.get(inputs, "file_path")
    ast = get_in(state, ["results", "parse_file", "ast"])
    {:ok, %{"summary" => "skill:#{file_path}:#{ast}"}}
  end
end

defmodule Jido.Code.Workflow.TestSkills.FailSkill do
  def handle_workflow_step(_inputs, _state), do: {:error, :boom}
end

defmodule Jido.Code.Workflow.TestSkills.NoHandlerSkill do
  def run(_inputs), do: :ok
end

defmodule Jido.Code.Workflow.Actions.ExecuteSkillStepTest do
  use ExUnit.Case, async: true

  alias Jido.Code.Workflow.Actions.ExecuteSkillStep
  alias Jido.Signal
  alias Jido.Signal.Bus

  test "executes configured skill module with resolved input references" do
    step = %{
      "name" => "run_skill",
      "module" => "Jido.Code.Workflow.TestSkills.EchoSkill",
      "inputs" => %{"file_path" => "`input:file_path`"}
    }

    params = %{
      "inputs" => %{"file_path" => "lib/example.ex"},
      "results" => %{"parse_file" => %{"ast" => "ast:lib/example.ex"}},
      step: step
    }

    assert {:ok, state} = ExecuteSkillStep.run(params, %{})

    assert state["results"]["run_skill"]["summary"] ==
             "skill:lib/example.ex:ast:lib/example.ex"
  end

  test "returns error when skill module is not loaded" do
    step = %{"name" => "run_skill", "module" => "Nope.Skill", "inputs" => %{}}

    assert {:error, {:module_not_loaded, "Nope.Skill"}} =
             ExecuteSkillStep.run(%{step: step}, %{})
  end

  test "returns error when module does not implement handle_workflow_step/2" do
    step = %{
      "name" => "run_skill",
      "module" => "Jido.Code.Workflow.TestSkills.NoHandlerSkill",
      "inputs" => %{}
    }

    assert {:error, {:invalid_skill_module, Jido.Code.Workflow.TestSkills.NoHandlerSkill}} =
             ExecuteSkillStep.run(%{step: step}, %{})
  end

  test "returns mapped error when skill execution fails" do
    step = %{
      "name" => "run_skill",
      "module" => "Jido.Code.Workflow.TestSkills.FailSkill",
      "inputs" => %{}
    }

    assert {:error, {:skill_failed, "Jido.Code.Workflow.TestSkills.FailSkill", :boom}} =
             ExecuteSkillStep.run(%{step: step}, %{})
  end

  test "broadcasts step started and completed signals for skill steps" do
    bus = start_test_bus()

    assert {:ok, _sub_id} =
             Bus.subscribe(bus, "workflow.step.*", dispatch: {:pid, target: self()})

    step = %{
      "name" => "run_skill",
      "type" => "skill",
      "module" => "Jido.Code.Workflow.TestSkills.EchoSkill",
      "inputs" => %{"file_path" => "`input:file_path`"}
    }

    params = %{
      "inputs" => %{
        "file_path" => "lib/example.ex",
        "__workflow" => workflow_context(bus, ["step_started", "step_completed"])
      },
      "results" => %{"parse_file" => %{"ast" => "ast:lib/example.ex"}},
      step: step
    }

    assert {:ok, _state} = ExecuteSkillStep.run(params, %{})

    assert_receive {:signal,
                    %Signal{
                      type: "workflow.step.started",
                      data: %{
                        "workflow_id" => "skill_test_workflow",
                        "run_id" => "run_skill_1",
                        "step" => %{"name" => "run_skill", "type" => "skill"}
                      }
                    }}

    assert_receive {:signal,
                    %Signal{
                      type: "workflow.step.completed",
                      data: %{
                        "workflow_id" => "skill_test_workflow",
                        "run_id" => "run_skill_1",
                        "step" => %{"name" => "run_skill", "type" => "skill"},
                        "status" => "completed"
                      }
                    }}
  end

  defp workflow_context(bus, events) do
    %{
      "workflow_id" => "skill_test_workflow",
      "run_id" => "run_skill_1",
      "bus" => bus,
      "source" => "/jido/code/workflow/workflow%3Askill_test",
      "publish_events" => events
    }
  end

  defp start_test_bus do
    bus = String.to_atom("jido_workflow_skill_test_bus_#{System.unique_integer([:positive])}")
    start_supervised!({Bus, name: bus})
    bus
  end
end
