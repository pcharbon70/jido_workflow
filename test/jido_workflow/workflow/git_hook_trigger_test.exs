defmodule JidoWorkflow.Workflow.GitHookTriggerTestActions.CaptureGitEvent do
  use Jido.Action,
    name: "git_hook_capture_event",
    schema: [
      trigger_type: [type: :string, required: true],
      git_event: [type: :string, required: true],
      branch: [type: :string, required: true],
      commit: [type: :string, required: true]
    ]

  @impl true
  def run(
        %{trigger_type: trigger_type, git_event: git_event, branch: branch, commit: commit},
        _context
      ) do
    {:ok,
     %{
       "trigger_type" => trigger_type,
       "git_event" => git_event,
       "branch" => branch,
       "commit" => commit
     }}
  end
end

defmodule JidoWorkflow.Workflow.GitHookTriggerTest do
  use ExUnit.Case, async: true

  alias Jido.Signal
  alias Jido.Signal.Bus
  alias JidoWorkflow.Workflow.Registry, as: WorkflowRegistry
  alias JidoWorkflow.Workflow.TriggerSupervisor

  setup do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "jido_workflow_git_hook_trigger_test_#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(tmp)
    File.mkdir_p!(tmp)

    repo_path = Path.join(tmp, "repo")
    File.mkdir_p!(repo_path)
    init_test_repo!(repo_path)

    workflow_dir = Path.join(tmp, "workflows")
    File.mkdir_p!(workflow_dir)

    bus = unique_name("git_hook_trigger_bus")
    start_supervised!({Bus, name: bus})

    workflow_registry = unique_name("git_hook_trigger_registry")

    {:ok, workflow_registry_pid} =
      start_supervised({WorkflowRegistry, workflow_dir: workflow_dir, name: workflow_registry})

    process_registry = unique_name("git_hook_trigger_process_registry")
    start_supervised!({Registry, keys: :unique, name: process_registry})

    trigger_supervisor = unique_name("git_hook_trigger_supervisor")
    start_supervised!({TriggerSupervisor, name: trigger_supervisor})

    write_git_hook_workflow(workflow_dir, "git_hook_flow")
    assert {:ok, %{total: 1}} = WorkflowRegistry.refresh(workflow_registry_pid)

    on_exit(fn -> File.rm_rf!(tmp) end)

    {:ok,
     repo_path: repo_path,
     bus: bus,
     workflow_registry: workflow_registry_pid,
     process_registry: process_registry,
     trigger_supervisor: trigger_supervisor}
  end

  test "executes workflow on commit file events", context do
    trigger_pid = start_git_hook_trigger(context, events: ["commit", "push"])

    assert {:ok, _sub_id} =
             Bus.subscribe(context.bus, "workflow.run.completed",
               dispatch: {:pid, target: self()}
             )

    commit_path = Path.join([context.repo_path, ".git", "COMMIT_EDITMSG"])
    send(trigger_pid, {:file_event, self(), {commit_path, [:modified]}})

    assert_receive {:signal,
                    %Signal{
                      type: "workflow.run.completed",
                      data: %{"workflow_id" => "git_hook_flow", "result" => result}
                    }},
                   5_000

    assert result["trigger_type"] == "git_hook"
    assert result["git_event"] == "commit"
    assert is_binary(result["branch"])
    assert result["branch"] != ""
    assert is_binary(result["commit"])
    assert result["commit"] != ""
  end

  test "filters git events based on configured event list", context do
    trigger_pid = start_git_hook_trigger(context, events: ["push"])

    assert {:ok, _sub_id} =
             Bus.subscribe(context.bus, "workflow.run.completed",
               dispatch: {:pid, target: self()}
             )

    commit_path = Path.join([context.repo_path, ".git", "COMMIT_EDITMSG"])
    send(trigger_pid, {:file_event, self(), {commit_path, [:modified]}})

    refute_receive {:signal, %Signal{type: "workflow.run.completed"}}, 300

    push_path = Path.join([context.repo_path, ".git", "refs", "heads", "main"])
    send(trigger_pid, {:file_event, self(), {push_path, [:modified]}})

    assert_receive {:signal,
                    %Signal{
                      type: "workflow.run.completed",
                      data: %{
                        "workflow_id" => "git_hook_flow",
                        "result" => %{"git_event" => "push"}
                      }
                    }},
                   5_000
  end

  test "fails to start when repo_path is invalid", context do
    assert {:error, {:invalid_config, :repo_path}} =
             TriggerSupervisor.start_trigger(
               %{
                 id: "git_hook_flow:git_hook:0",
                 workflow_id: "git_hook_flow",
                 type: "git_hook",
                 repo_path: Path.join(context.repo_path, "missing"),
                 workflow_registry: context.workflow_registry,
                 bus: context.bus
               },
               supervisor: context.trigger_supervisor,
               process_registry: context.process_registry
             )
  end

  defp start_git_hook_trigger(context, opts) do
    trigger_id = "git_hook_flow:git_hook:0"
    events = Keyword.get(opts, :events, ["commit", "push"])

    assert {:ok, pid} =
             TriggerSupervisor.start_trigger(
               %{
                 id: trigger_id,
                 workflow_id: "git_hook_flow",
                 type: "git_hook",
                 events: events,
                 repo_path: context.repo_path,
                 workflow_registry: context.workflow_registry,
                 bus: context.bus
               },
               supervisor: context.trigger_supervisor,
               process_registry: context.process_registry
             )

    pid
  end

  defp write_git_hook_workflow(dir, name) do
    path = Path.join(dir, "#{name}.md")

    markdown = """
    ---
    name: #{name}
    version: "1.0.0"
    enabled: true
    ---

    # #{name}

    ## Steps

    ### capture_git_event
    - **type**: action
    - **module**: JidoWorkflow.Workflow.GitHookTriggerTestActions.CaptureGitEvent
    - **inputs**:
      - trigger_type: `input:trigger_type`
      - git_event: `input:git_event`
      - branch: `input:branch`
      - commit: `input:commit`

    ## Return
    - **value**: capture_git_event
    """

    File.write!(path, markdown)
    path
  end

  defp init_test_repo!(repo_path) do
    run_git!(repo_path, ["init", "-q"])
    run_git!(repo_path, ["config", "user.email", "test@example.com"])
    run_git!(repo_path, ["config", "user.name", "Test User"])

    File.write!(Path.join(repo_path, "README.md"), "# test repo\n")
    run_git!(repo_path, ["add", "README.md"])
    run_git!(repo_path, ["commit", "-m", "initial commit", "-q"])
  end

  defp run_git!(repo_path, args) do
    case System.cmd("git", args, cd: repo_path, stderr_to_stdout: true) do
      {_output, 0} ->
        :ok

      {output, status} ->
        raise "git #{Enum.join(args, " ")} failed with status #{status}: #{output}"
    end
  end

  defp unique_name(prefix) do
    :"#{prefix}_#{System.unique_integer([:positive])}"
  end
end
