defmodule Jido.Code.Workflow.CLITest do
  use ExUnit.Case, async: true

  alias Jido.Code.Workflow.CLI

  test "routes workflow id and option pairs to workflow.run" do
    assert {:ok, "workflow.run", ["code_review", "--inputs", encoded_inputs]} =
             CLI.resolve([
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

  test "routes task-mode flags to their mix tasks" do
    assert {:ok, "workflow.control", ["list", "--status", "running"]} =
             CLI.resolve(["--control", "list", "--status", "running"])

    assert {:ok, "workflow.signal", ["workflow.run.list.requested", "--data", ~s({"limit":5})]} =
             CLI.resolve(["--signal", "workflow.run.list.requested", "--data", ~s({"limit":5})])

    assert {:ok, "workflow.watch", []} = CLI.resolve(["--watch"])

    assert {:ok, "workflow.command", ["/workflow:review", "--workflow-id", "code_review"]} =
             CLI.resolve(["--command", "/workflow:review", "--workflow-id", "code_review"])
  end

  test "rejects task-mode flags missing required positional arguments" do
    assert {:error, :missing_command} = CLI.resolve(["--control"])
    assert {:error, :missing_command} = CLI.resolve(["--signal"])
    assert {:error, :missing_command} = CLI.resolve(["--command"])
  end

  test "decodes JSON literals for non-reserved input option values" do
    assert {:ok, "workflow.run", ["code_review", "--inputs", encoded_inputs]} =
             CLI.resolve([
               "code_review",
               "-attempts",
               "3",
               "-dry-run",
               "true",
               "-score",
               "9.5",
               "-metadata",
               ~s({"severity":"high"}),
               "-files",
               ~s(["lib/a.ex","lib/b.ex"]),
               "-note",
               "plain_text"
             ])

    assert Jason.decode!(encoded_inputs) == %{
             "attempts" => 3,
             "dry_run" => true,
             "score" => 9.5,
             "metadata" => %{"severity" => "high"},
             "files" => ["lib/a.ex", "lib/b.ex"],
             "note" => "plain_text"
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
    assert {:ok, "workflow.run", ["my_flow"]} = CLI.resolve(["my_flow"])
  end

  test "rejects missing and invalid workflow identifiers" do
    assert {:error, :missing_command} = CLI.resolve([])
    assert {:error, :invalid_workflow_name} = CLI.resolve(["/workflow:review"])
  end

  test "rejects malformed option pairs" do
    assert {:error, :invalid_option_pairs} =
             CLI.resolve(["code_review", "-file-path"])

    assert {:error, :invalid_option_pairs} =
             CLI.resolve(["code_review", "file-path", "lib/example.ex"])

    assert {:error, :invalid_option_pairs} =
             CLI.resolve(["code_review", "--file-path", "lib/example.ex"])
  end

  test "rejects invalid reserved run option values" do
    assert {:error, :invalid_option_pairs} =
             CLI.resolve(["code_review", "-backend", "unknown"])

    assert {:error, :invalid_option_pairs} =
             CLI.resolve(["code_review", "-timeout", "0"])

    assert {:error, :invalid_option_pairs} =
             CLI.resolve(["code_review", "-await-completion", "maybe"])
  end

  test "routes help inputs to usage" do
    assert {:error, :help} = CLI.resolve(["help"])
    assert {:error, :help} = CLI.resolve(["--help"])
    assert {:error, :help} = CLI.resolve(["-h"])
  end
end
