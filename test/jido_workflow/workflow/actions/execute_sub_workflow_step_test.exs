defmodule JidoWorkflow.Workflow.Actions.ExecuteSubWorkflowStepTestActions.Produce do
  use Jido.Action,
    name: "subworkflow_produce",
    schema: [
      value: [type: :string, required: true]
    ]

  @impl true
  def run(%{value: value}, _context) do
    {:ok, %{"value" => "child:#{value}"}}
  end
end

defmodule JidoWorkflow.Workflow.Actions.ExecuteSubWorkflowStepTest do
  use ExUnit.Case, async: true

  alias JidoWorkflow.Workflow.Actions.ExecuteSubWorkflowStep
  alias JidoWorkflow.Workflow.Registry
  alias JidoWorkflow.Workflow.RunStore

  setup do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "jido_workflow_subworkflow_action_test_#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(tmp)
    File.mkdir_p!(tmp)

    on_exit(fn -> File.rm_rf!(tmp) end)
    {:ok, tmp_dir: tmp}
  end

  test "executes configured sub-workflow with resolved inputs", %{tmp_dir: tmp_dir} do
    write_sub_workflow(tmp_dir, "child_flow")
    {:ok, registry} = start_supervised({Registry, workflow_dir: tmp_dir, name: unique_name()})
    assert {:ok, %{total: 1}} = Registry.refresh(registry)

    step = %{
      "name" => "invoke_child",
      "workflow" => "child_flow",
      "inputs" => %{"value" => "`input:source`"}
    }

    params = %{
      step: step,
      registry: registry,
      input: [%{"inputs" => %{"source" => "lib/example.ex"}, "results" => %{}}]
    }

    assert {:ok, state} = ExecuteSubWorkflowStep.run(params, %{})
    assert state["results"]["invoke_child"]["value"] == "child:lib/example.ex"
  end

  test "skips execution when condition resolves false", %{tmp_dir: tmp_dir} do
    {:ok, registry} = start_supervised({Registry, workflow_dir: tmp_dir, name: unique_name()})
    assert {:ok, %{total: 0}} = Registry.refresh(registry)

    step = %{
      "name" => "invoke_child",
      "workflow" => "missing_flow",
      "inputs" => 42,
      "condition" => false
    }

    assert {:ok, state} =
             ExecuteSubWorkflowStep.run(
               %{step: step, registry: registry, source: "ignored"},
               %{}
             )

    assert state["results"]["invoke_child"] == %{
             "status" => "skipped",
             "reason" => "condition_not_met"
           }
  end

  test "returns mapped not found error for missing sub-workflow", %{tmp_dir: tmp_dir} do
    {:ok, registry} = start_supervised({Registry, workflow_dir: tmp_dir, name: unique_name()})
    assert {:ok, %{total: 0}} = Registry.refresh(registry)

    step = %{
      "name" => "invoke_child",
      "workflow" => "missing_flow",
      "inputs" => %{"value" => "`input:source`"}
    }

    assert {:error, {:sub_workflow_not_found, "missing_flow"}} =
             ExecuteSubWorkflowStep.run(%{step: step, registry: registry, source: "x"}, %{})
  end

  test "inherits backend from workflow context when backend param is not set", %{tmp_dir: tmp_dir} do
    write_sub_workflow(tmp_dir, "child_flow")
    {:ok, registry} = start_supervised({Registry, workflow_dir: tmp_dir, name: unique_name()})
    {:ok, run_store} = start_supervised({RunStore, name: unique_name("run_store")})
    assert {:ok, %{total: 1}} = Registry.refresh(registry)

    step = %{
      "name" => "invoke_child",
      "workflow" => "child_flow",
      "inputs" => %{"value" => "`input:source`"}
    }

    params = %{
      step: step,
      registry: registry,
      run_store: run_store,
      input: [
        %{
          "inputs" => %{
            "source" => "lib/example.ex",
            "__workflow" => %{"backend" => "strategy"}
          },
          "results" => %{}
        }
      ]
    }

    assert {:ok, state} = ExecuteSubWorkflowStep.run(params, %{})
    assert state["results"]["invoke_child"]["value"] == "child:lib/example.ex"

    assert [%{workflow_id: "child_flow", backend: :strategy, status: :completed}] =
             RunStore.list(run_store)
  end

  test "explicit backend param overrides workflow context backend", %{tmp_dir: tmp_dir} do
    write_sub_workflow(tmp_dir, "child_flow")
    {:ok, registry} = start_supervised({Registry, workflow_dir: tmp_dir, name: unique_name()})
    {:ok, run_store} = start_supervised({RunStore, name: unique_name("run_store")})
    assert {:ok, %{total: 1}} = Registry.refresh(registry)

    step = %{
      "name" => "invoke_child",
      "workflow" => "child_flow",
      "inputs" => %{"value" => "`input:source`"}
    }

    params = %{
      step: step,
      registry: registry,
      run_store: run_store,
      backend: "direct",
      input: [
        %{
          "inputs" => %{
            "source" => "lib/example.ex",
            "__workflow" => %{"backend" => "strategy"}
          },
          "results" => %{}
        }
      ]
    }

    assert {:ok, state} = ExecuteSubWorkflowStep.run(params, %{})
    assert state["results"]["invoke_child"]["value"] == "child:lib/example.ex"

    assert [%{workflow_id: "child_flow", backend: :direct, status: :completed}] =
             RunStore.list(run_store)
  end

  defp write_sub_workflow(dir, name) do
    path = Path.join(dir, "#{name}.md")

    markdown = """
    ---
    name: #{name}
    version: "1.0.0"
    enabled: true
    ---

    # #{name}

    ## Steps

    ### produce
    - **type**: action
    - **module**: JidoWorkflow.Workflow.Actions.ExecuteSubWorkflowStepTestActions.Produce
    - **inputs**:
      - value: `input:value`

    ## Return
    - **value**: produce
    """

    File.write!(path, markdown)
    path
  end

  defp unique_name(prefix \\ "registry") do
    :"workflow_subflow_action_#{prefix}_#{System.unique_integer([:positive])}"
  end
end
