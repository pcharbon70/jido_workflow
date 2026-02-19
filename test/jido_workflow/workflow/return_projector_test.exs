defmodule JidoWorkflow.Workflow.ReturnProjectorTest do
  use ExUnit.Case, async: true

  alias JidoWorkflow.Workflow.ReturnProjector

  test "returns last production when return config is nil" do
    productions = [1, 2, 3]

    assert {:ok, 3} = ReturnProjector.project(productions, nil)
  end

  test "returns configured step result from workflow state" do
    productions = [
      %{
        "inputs" => %{"file_path" => "lib/example.ex"},
        "results" => %{
          "parse_file" => %{"ast" => "ast:lib/example.ex"},
          "build_summary" => %{"summary" => "ok"}
        }
      }
    ]

    config = %{value: "build_summary", transform: nil}

    assert {:ok, %{"summary" => "ok"}} = ReturnProjector.project(productions, config)
  end

  test "supports nested result path return values" do
    productions = [
      %{
        "inputs" => %{},
        "results" => %{
          "analyze" => %{"output" => %{"score" => 42}}
        }
      }
    ]

    config = %{value: "analyze.output.score", transform: nil}

    assert {:ok, 42} = ReturnProjector.project(productions, config)
  end

  test "returns configured step result when last production does not include the step" do
    productions = [
      %{
        "inputs" => %{},
        "results" => %{
          "build_summary" => %{"summary" => "ok"}
        }
      },
      %{"metadata" => %{"status" => "done"}}
    ]

    config = %{value: "build_summary", transform: nil}

    assert {:ok, %{"summary" => "ok"}} = ReturnProjector.project(productions, config)
  end

  test "applies transform function source" do
    productions = [%{"value" => 21}]

    config = %{
      value: "value",
      transform: "fn value -> value * 2 end"
    }

    assert {:ok, 42} = ReturnProjector.project(productions, config)
  end

  test "returns error when productions are empty" do
    assert {:error, :no_productions} = ReturnProjector.project([], nil)
  end
end
