defmodule Jido.Code.Workflow.ArgumentResolverTest do
  use ExUnit.Case, async: true

  alias Jido.Code.Workflow.ArgumentResolver

  describe "normalize_state/1" do
    test "normalizes plain input maps into workflow state" do
      state = ArgumentResolver.normalize_state(%{"file_path" => "lib/example.ex"})

      assert state == %{
               "inputs" => %{"file_path" => "lib/example.ex"},
               "results" => %{}
             }
    end

    test "normalizes and merges list state inputs/results" do
      state =
        ArgumentResolver.normalize_state([
          %{"inputs" => %{"a" => 1}, "results" => %{"step_a" => %{"ok" => true}}},
          %{inputs: %{b: 2}, results: %{"step_b" => %{ok: true}}}
        ])

      assert state["inputs"]["a"] == 1
      assert state["inputs"]["b"] == 2
      assert state["results"]["step_a"]["ok"] == true
      assert state["results"]["step_b"]["ok"] == true
    end
  end

  describe "resolve_inputs/2" do
    test "resolves input and result references" do
      state = %{
        "inputs" => %{"file_path" => "lib/example.ex"},
        "results" => %{"parse_file" => %{"ast" => "AST"}}
      }

      inputs = %{
        "path" => "`input:file_path`",
        "ast" => "`result:parse_file.ast`",
        "label" => "static"
      }

      assert {:ok, resolved} = ArgumentResolver.resolve_inputs(inputs, state)
      assert resolved == %{"path" => "lib/example.ex", "ast" => "AST", "label" => "static"}
    end
  end

  describe "put_result/3" do
    test "adds step results to workflow state" do
      state = %{"inputs" => %{}, "results" => %{}}
      updated = ArgumentResolver.put_result(state, "parse_file", %{"ok" => true})

      assert updated["results"]["parse_file"] == %{"ok" => true}
    end
  end
end
