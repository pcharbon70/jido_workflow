defmodule Jido.Code.Workflow.CLITest do
  use ExUnit.Case, async: true

  alias Jido.Code.Workflow.CLI

  test "routes workflow id and option pairs to workflow.run" do
    assert {:ok, "workflow.run", ["code_review", "--inputs", encoded_inputs]} =
             CLI.resolve([
               "--workflow",
               "code_review",
               "-file-path",
               "lib/example.ex",
               "-mode",
               "full"
             ])

    assert Jason.decode!(encoded_inputs) == %{
             "file_path" => "lib/example.ex",
             "mode" => "full"
           }
  end

  test "routes reserved run options while keeping non-reserved options as inputs" do
    assert {:ok, "workflow.run",
            [
              "code_review",
              "--run-id",
              "run_123",
              "--backend",
              "strategy",
              "--source",
              "/terminal",
              "--bus",
              "jido_workflow_bus",
              "--timeout",
              "45000",
              "--no-start-app",
              "--no-await-completion",
              "--pretty",
              "--inputs",
              encoded_inputs
            ]} =
             CLI.resolve([
               "--workflow",
               "code_review",
               "-run-id",
               "run_123",
               "-backend",
               "strategy",
               "-source",
               "/terminal",
               "-bus",
               "jido_workflow_bus",
               "-timeout",
               "45000",
               "-start-app",
               "false",
               "-await-completion",
               "0",
               "-pretty",
               "true",
               "-file-path",
               "lib/example.ex",
               "-mode",
               "full"
             ])

    assert Jason.decode!(encoded_inputs) == %{
             "file_path" => "lib/example.ex",
             "mode" => "full"
           }
  end

  test "routes workflow id with no options to workflow.run" do
    assert {:ok, "workflow.run", ["my_flow"]} = CLI.resolve(["--workflow", "my_flow"])
  end

  test "rejects missing and unknown commands" do
    assert {:error, :missing_command} = CLI.resolve([])
    assert {:error, :missing_workflow} = CLI.resolve(["--workflow"])
    assert {:error, :invalid_workflow_name} = CLI.resolve(["--workflow", "/workflow:review"])
  end

  test "rejects malformed option pairs" do
    assert {:error, :invalid_option_pairs} =
             CLI.resolve(["--workflow", "code_review", "-file-path"])

    assert {:error, :invalid_option_pairs} =
             CLI.resolve(["--workflow", "code_review", "file-path", "lib/example.ex"])

    assert {:error, :invalid_option_pairs} =
             CLI.resolve(["--workflow", "code_review", "--file-path", "lib/example.ex"])
  end

  test "rejects invalid reserved run option values" do
    assert {:error, :invalid_option_pairs} =
             CLI.resolve(["--workflow", "code_review", "-backend", "unknown"])

    assert {:error, :invalid_option_pairs} =
             CLI.resolve(["--workflow", "code_review", "-timeout", "0"])

    assert {:error, :invalid_option_pairs} =
             CLI.resolve(["--workflow", "code_review", "-await-completion", "maybe"])
  end

  test "rejects workflow commands without --workflow prefix" do
    assert {:error, :workflow_prefix_required} = CLI.resolve(["my_flow", "-mode", "full"])
    assert {:error, :workflow_prefix_required} = CLI.resolve(["run", "my_flow"])
  end

  test "routes help inputs to usage" do
    assert {:error, :help} = CLI.resolve(["help"])
    assert {:error, :help} = CLI.resolve(["--help"])
    assert {:error, :help} = CLI.resolve(["-h"])
  end
end
