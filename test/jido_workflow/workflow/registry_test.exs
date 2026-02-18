defmodule JidoWorkflow.Workflow.RegistryTest do
  use ExUnit.Case, async: true

  alias JidoWorkflow.Workflow.Registry

  setup do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "jido_workflow_registry_test_#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(tmp)
    File.mkdir_p!(tmp)

    on_exit(fn -> File.rm_rf!(tmp) end)
    {:ok, tmp_dir: tmp}
  end

  test "loads workflows and respects enabled flag", %{tmp_dir: tmp_dir} do
    write_workflow(tmp_dir, "enabled_flow", enabled: true)
    write_workflow(tmp_dir, "disabled_flow", enabled: false)

    {:ok, pid} =
      start_supervised(
        {Registry,
         workflow_dir: tmp_dir,
         compile_fun: fn definition ->
           {:ok, %{id: definition.name, version: definition.version}}
         end,
         name: unique_name()}
      )

    assert {:ok, %{total: 2}} = Registry.refresh(pid)
    assert {:ok, %{id: "enabled_flow"}} = Registry.get_compiled("enabled_flow", pid)
    assert {:error, :disabled} = Registry.get_compiled("disabled_flow", pid)
  end

  test "refresh skips unchanged files and preserves compile cache", %{tmp_dir: tmp_dir} do
    write_workflow(tmp_dir, "cache_flow")
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    compile_fun = fn definition ->
      Agent.update(counter, &(&1 + 1))
      {:ok, %{name: definition.name}}
    end

    {:ok, pid} =
      start_supervised(
        {Registry, workflow_dir: tmp_dir, compile_fun: compile_fun, name: unique_name()}
      )

    assert {:ok, %{total: 1}} = Registry.refresh(pid)
    assert Agent.get(counter, & &1) == 1

    assert {:ok, %{skipped: 1}} = Registry.refresh(pid)
    assert Agent.get(counter, & &1) == 1
  end

  test "refresh detects modified files and recompiles", %{tmp_dir: tmp_dir} do
    path = write_workflow(tmp_dir, "mutable_flow", version: "1.0.0")

    {:ok, pid} =
      start_supervised(
        {Registry,
         workflow_dir: tmp_dir,
         compile_fun: fn definition ->
           {:ok, %{name: definition.name, version: definition.version}}
         end,
         name: unique_name()}
      )

    assert {:ok, %{version: "1.0.0"}} = Registry.get_compiled("mutable_flow", pid)

    write_workflow_file(path, "mutable_flow", version: "1.0.1")
    assert {:ok, %{changed: 1}} = Registry.refresh(pid)
    assert {:ok, %{version: "1.0.1"}} = Registry.get_compiled("mutable_flow", pid)
  end

  test "reload forces recompilation of a specific workflow", %{tmp_dir: tmp_dir} do
    write_workflow(tmp_dir, "reload_flow")
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    compile_fun = fn definition ->
      Agent.update(counter, &(&1 + 1))
      {:ok, %{name: definition.name}}
    end

    {:ok, pid} =
      start_supervised(
        {Registry, workflow_dir: tmp_dir, compile_fun: compile_fun, name: unique_name()}
      )

    assert {:ok, %{total: 1}} = Registry.refresh(pid)
    assert Agent.get(counter, & &1) == 1

    assert {:ok, %{changed: 1}} = Registry.reload("reload_flow", pid)
    assert Agent.get(counter, & &1) == 2
  end

  test "refresh removes deleted workflow files from cache", %{tmp_dir: tmp_dir} do
    path = write_workflow(tmp_dir, "delete_me")

    {:ok, pid} = start_supervised({Registry, workflow_dir: tmp_dir, name: unique_name()})
    assert {:ok, %{total: 1}} = Registry.refresh(pid)
    assert {:ok, _compiled} = Registry.get_compiled("delete_me", pid)

    File.rm!(path)
    assert {:ok, %{removed: 1, total: 0}} = Registry.refresh(pid)
    assert {:error, :not_found} = Registry.get_compiled("delete_me", pid)
  end

  test "invalid markdown files are indexed as invalid entries", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "broken.md"), "# missing frontmatter\n")

    {:ok, pid} = start_supervised({Registry, workflow_dir: tmp_dir, name: unique_name()})
    assert {:ok, %{total: 1}} = Registry.refresh(pid)

    [entry] = Registry.list(pid, include_invalid: true)
    assert entry.valid? == false
    assert {:error, :disabled} = Registry.get_compiled("broken", pid)
  end

  defp write_workflow(tmp_dir, name, opts \\ []) do
    path = Path.join(tmp_dir, "#{name}.md")
    write_workflow_file(path, name, opts)
    path
  end

  defp write_workflow_file(path, name, opts) do
    version = Keyword.get(opts, :version, "1.0.0")
    enabled = Keyword.get(opts, :enabled, true)

    markdown = """
    ---
    name: #{name}
    version: "#{version}"
    enabled: #{enabled}
    ---

    # #{name}

    ## Steps

    ### first_step
    - **type**: action
    - **module**: Example.Actions.FirstStep
    - **inputs**:
      - value: `input:value`

    ## Return
    - **value**: first_step
    """

    File.write!(path, markdown)
  end

  defp unique_name do
    :"workflow_registry_#{System.unique_integer([:positive])}"
  end
end
