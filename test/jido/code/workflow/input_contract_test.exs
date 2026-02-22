defmodule Jido.Code.Workflow.InputContractTest do
  use ExUnit.Case, async: true

  alias Jido.Code.Workflow.Definition.Input, as: DefinitionInput
  alias Jido.Code.Workflow.InputContract
  alias Jido.Code.Workflow.ValidationError

  describe "compile_schema/1" do
    test "serializes workflow input declarations into runtime schema maps" do
      inputs = [
        %DefinitionInput{
          name: "file_path",
          type: "string",
          required: true,
          default: nil,
          description: "Path to file"
        },
        %DefinitionInput{
          name: "max_retries",
          type: "integer",
          required: false,
          default: 3,
          description: nil
        }
      ]

      assert InputContract.compile_schema(inputs) == [
               %{
                 name: "file_path",
                 type: "string",
                 required: true,
                 default: nil,
                 description: "Path to file"
               },
               %{
                 name: "max_retries",
                 type: "integer",
                 required: false,
                 default: 3,
                 description: nil
               }
             ]
    end
  end

  describe "normalize_inputs/2" do
    test "applies optional defaults and preserves undeclared inputs" do
      schema = [
        %{
          name: "file_path",
          type: "string",
          required: true,
          default: nil,
          description: nil
        },
        %{
          name: "max_retries",
          type: "integer",
          required: false,
          default: 3,
          description: nil
        }
      ]

      assert {:ok, normalized} =
               InputContract.normalize_inputs(
                 %{"file_path" => "lib/example.ex", "extra" => true},
                 schema
               )

      assert normalized["file_path"] == "lib/example.ex"
      assert normalized["max_retries"] == 3
      assert normalized["extra"] == true
    end

    test "returns required error for missing required input" do
      schema = [
        %{name: "file_path", type: "string", required: true, default: nil, description: nil}
      ]

      assert {:error, [%ValidationError{path: ["inputs", "file_path"], code: :required}]} =
               InputContract.normalize_inputs(%{}, schema)
    end

    test "returns invalid_type for mismatched input values" do
      schema = [
        %{name: "retry_count", type: "integer", required: true, default: nil, description: nil}
      ]

      assert {:error, [%ValidationError{path: ["inputs", "retry_count"], code: :invalid_type}]} =
               InputContract.normalize_inputs(%{"retry_count" => "3"}, schema)
    end
  end
end
