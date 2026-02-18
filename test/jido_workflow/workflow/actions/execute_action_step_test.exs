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

defmodule JidoWorkflow.Workflow.Actions.ExecuteActionStepTest do
  use ExUnit.Case, async: true

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
end
