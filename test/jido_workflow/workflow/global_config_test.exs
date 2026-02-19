defmodule JidoWorkflow.Workflow.GlobalConfigTest do
  use ExUnit.Case, async: true

  alias JidoWorkflow.Workflow.GlobalConfig
  alias JidoWorkflow.Workflow.ValidationError

  setup do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "jido_workflow_global_config_test_#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(tmp)
    File.mkdir_p!(tmp)

    on_exit(fn -> File.rm_rf!(tmp) end)

    {:ok, tmp_dir: tmp}
  end

  test "load_file/1 returns empty overrides when config file is missing", context do
    path = Path.join(context.tmp_dir, ".jido_code/config.json")
    assert {:ok, %{}} = GlobalConfig.load_file(path)
  end

  test "load_file/1 normalizes runtime overrides from config file", context do
    config_dir = Path.join(context.tmp_dir, ".jido_code")
    File.mkdir_p!(config_dir)
    config_path = Path.join(config_dir, "config.json")

    File.write!(
      config_path,
      Jason.encode!(%{
        "workflow_dir" => "workflows",
        "trigger_sync_interval_ms" => 2500,
        "trigger_backend" => "strategy"
      })
    )

    assert {:ok, overrides} = GlobalConfig.load_file(config_path)

    assert overrides.workflow_dir == Path.join(config_dir, "workflows")
    assert overrides.trigger_sync_interval_ms == 2500
    assert overrides.trigger_backend == :strategy
    refute Map.has_key?(overrides, :triggers_config_path)
  end

  test "load_file/1 supports nested workflow configuration", context do
    config_dir = Path.join(context.tmp_dir, ".jido_code")
    File.mkdir_p!(config_dir)
    config_path = Path.join(config_dir, "config.json")

    File.write!(
      config_path,
      Jason.encode!(%{
        "workflow" => %{
          "workflow_dir" => "workflows",
          "triggers_config_path" => "workflows/triggers.json",
          "trigger_backend" => "direct"
        }
      })
    )

    assert {:ok, overrides} = GlobalConfig.load_file(config_path)

    assert overrides.workflow_dir == Path.join(config_dir, "workflows")
    assert overrides.triggers_config_path == Path.join(config_dir, "workflows/triggers.json")
    assert overrides.trigger_backend == :direct
  end

  test "load_file/1 returns path-aware errors for invalid values", context do
    config_dir = Path.join(context.tmp_dir, ".jido_code")
    File.mkdir_p!(config_dir)
    config_path = Path.join(config_dir, "config.json")

    File.write!(
      config_path,
      Jason.encode!(%{
        "workflow_dir" => "",
        "trigger_sync_interval_ms" => 0,
        "trigger_backend" => "invalid"
      })
    )

    assert {:error, errors} = GlobalConfig.load_file(config_path)
    assert is_list(errors)
    assert Enum.all?(errors, &match?(%ValidationError{}, &1))

    assert Enum.any?(errors, fn error ->
             error.path == ["workflow_dir"] and error.code == :invalid_value
           end)

    assert Enum.any?(errors, fn error ->
             error.path == ["trigger_sync_interval_ms"] and error.code == :invalid_value
           end)

    assert Enum.any?(errors, fn error ->
             error.path == ["trigger_backend"] and error.code == :invalid_value
           end)
  end
end
