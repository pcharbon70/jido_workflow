defmodule Jido.Code.Workflow.CLITest do
  use ExUnit.Case, async: true

  alias Jido.Code.Workflow.CLI

  test "routes slash-prefixed command to workflow.command when --workflow is first" do
    assert {:ok, "workflow.command", ["/workflow:review", "--workflow-id", "code_review"]} =
             CLI.resolve(["--workflow", "/workflow:review", "--workflow-id", "code_review"])
  end

  test "routes command subcommand to workflow.command when --workflow is first" do
    assert {:ok, "workflow.command", ["/workflow:review", "--params", ~s({"value":"ok"})]} =
             CLI.resolve([
               "--workflow",
               "command",
               "/workflow:review",
               "--params",
               ~s({"value":"ok"})
             ])
  end

  test "supports optional workflow prefix" do
    assert {:ok, "workflow.control", ["list", "--status", "running"]} =
             CLI.resolve(["--workflow", "workflow", "control", "list", "--status", "running"])
  end

  test "routes named subcommands" do
    assert {:ok, "workflow.run", ["my_flow"]} = CLI.resolve(["--workflow", "run", "my_flow"])

    assert {:ok, "workflow.signal", ["workflow.runtime.status.requested"]} =
             CLI.resolve(["--workflow", "signal", "workflow.runtime.status.requested"])

    assert {:ok, "workflow.watch", ["--limit", "5"]} =
             CLI.resolve(["--workflow", "watch", "--limit", "5"])
  end

  test "rejects missing and unknown commands" do
    assert {:error, :missing_command} = CLI.resolve([])
    assert {:error, :unknown_command} = CLI.resolve(["--workflow", "unknown"])
  end

  test "rejects workflow commands without --workflow prefix" do
    assert {:error, :workflow_prefix_required} = CLI.resolve(["run", "my_flow"])
    assert {:error, :workflow_prefix_required} = CLI.resolve(["/workflow:review"])
  end

  test "routes help inputs to usage" do
    assert {:error, :help} = CLI.resolve(["help"])
    assert {:error, :help} = CLI.resolve(["--help"])
    assert {:error, :help} = CLI.resolve(["-h"])
  end
end
