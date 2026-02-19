defmodule JidoWorkflow.Workflow.TriggerConfigTest do
  use ExUnit.Case, async: true

  alias JidoWorkflow.Workflow.TriggerConfig

  setup do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "jido_workflow_trigger_config_test_#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(tmp)
    File.mkdir_p!(tmp)

    on_exit(fn -> File.rm_rf!(tmp) end)

    {:ok, tmp_dir: tmp}
  end

  test "load_document/1 returns an empty document when file does not exist", context do
    missing_path = Path.join(context.tmp_dir, "missing.json")

    assert {:ok, %{global_settings: %{}, triggers: []}} =
             TriggerConfig.load_document(missing_path)

    assert {:ok, []} = TriggerConfig.load_file(missing_path)
  end

  test "load_document/1 normalizes global settings and trigger entries", context do
    config_path = Path.join(context.tmp_dir, "triggers.json")

    File.write!(
      config_path,
      Jason.encode!(%{
        "global_settings" => %{
          "default_debounce_ms" => 25,
          "max_concurrent_triggers" => 2
        },
        "triggers" => [
          %{
            "id" => "trigger:one",
            "workflow_id" => "example_workflow",
            "type" => "file_system",
            "enabled" => true,
            "config" => %{"patterns" => ["watched/**/*.ex"]}
          },
          %{
            "id" => "trigger:two",
            "workflow_id" => "example_workflow",
            "type" => "manual",
            "enabled" => false
          }
        ]
      })
    )

    assert {:ok, document} = TriggerConfig.load_document(config_path)

    assert document.global_settings == %{
             default_debounce_ms: 25,
             max_concurrent_triggers: 2
           }

    assert length(document.triggers) == 2

    [first, second] = document.triggers

    assert first.id == "trigger:one"
    assert first.workflow_id == "example_workflow"
    assert first.type == "file_system"
    assert first.enabled == true
    assert first["patterns"] == ["watched/**/*.ex"]

    assert second.id == "trigger:two"
    assert second.workflow_id == "example_workflow"
    assert second.type == "manual"
    assert second.enabled == false

    assert {:ok, triggers} = TriggerConfig.load_file(config_path)
    assert triggers == document.triggers
  end
end
