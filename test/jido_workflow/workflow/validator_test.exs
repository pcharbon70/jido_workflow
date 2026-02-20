defmodule JidoWorkflow.Workflow.ValidatorTest do
  use ExUnit.Case, async: true

  alias JidoWorkflow.Workflow.Definition
  alias JidoWorkflow.Workflow.Validator

  describe "validate/1" do
    test "normalizes a valid definition into typed structs" do
      attrs = %{
        "name" => "code_review_pipeline",
        "version" => "1.0.0",
        "enabled" => true,
        "inputs" => [
          %{"name" => "file_path", "type" => "string", "required" => true}
        ],
        "triggers" => [
          %{"type" => "signal", "patterns" => ["code.review.requested"]}
        ],
        "settings" => %{
          "max_concurrency" => 4,
          "timeout_ms" => 300_000,
          "retry_policy" => %{
            "max_retries" => 3,
            "backoff" => "exponential",
            "base_delay_ms" => 1000
          },
          "on_failure" => "compensate"
        },
        "signals" => %{
          "topic" => "workflow:code_review_pipeline",
          "publish_events" => ["step_started", "workflow_complete"]
        },
        "steps" => [
          %{
            "name" => "parse_file",
            "type" => "action",
            "module" => "JidoCode.Actions.ParseElixirFile",
            "inputs" => %{"file_path" => "`input:file_path`"}
          },
          %{
            "name" => "ai_code_review",
            "type" => "agent",
            "agent" => "code_reviewer",
            "callback_signal" => "security.scan.complete",
            "depends_on" => ["parse_file"]
          }
        ],
        "return" => %{"value" => "ai_code_review"}
      }

      assert {:ok, %Definition{} = definition} = Validator.validate(attrs)
      assert definition.name == "code_review_pipeline"
      assert definition.version == "1.0.0"
      assert length(definition.inputs) == 1
      assert length(definition.triggers) == 1
      assert length(definition.steps) == 2
      assert definition.settings.max_concurrency == 4
      assert definition.signals.topic == "workflow:code_review_pipeline"
      assert definition.signals.publish_events == ["step_started", "workflow_complete"]
      assert Enum.at(definition.steps, 1).callback_signal == "security.scan.complete"
    end

    test "returns path-aware errors for invalid name and version" do
      attrs = %{
        "name" => "Bad-Name",
        "version" => "v1",
        "steps" => []
      }

      assert {:error, errors} = Validator.validate(attrs)
      assert Enum.any?(errors, &(&1.path == ["name"] and &1.code == :invalid_format))
      assert Enum.any?(errors, &(&1.path == ["version"] and &1.code == :invalid_format))
    end

    test "requires module for action steps" do
      attrs = %{
        "name" => "example_workflow",
        "version" => "1.0.0",
        "steps" => [
          %{"name" => "parse", "type" => "action"}
        ]
      }

      assert {:error, errors} = Validator.validate(attrs)

      assert Enum.any?(errors, fn error ->
               error.path == ["steps", "0", "module"] and error.code == :required
             end)
    end

    test "requires module for skill steps" do
      attrs = %{
        "name" => "example_workflow",
        "version" => "1.0.0",
        "steps" => [
          %{"name" => "apply_skill", "type" => "skill"}
        ]
      }

      assert {:error, errors} = Validator.validate(attrs)

      assert Enum.any?(errors, fn error ->
               error.path == ["steps", "0", "module"] and error.code == :required
             end)
    end

    test "rejects unsupported trigger types" do
      attrs = %{
        "name" => "example_workflow",
        "version" => "1.0.0",
        "triggers" => [
          %{"type" => "unknown_trigger"}
        ],
        "steps" => []
      }

      assert {:error, errors} = Validator.validate(attrs)

      assert Enum.any?(errors, fn error ->
               error.path == ["triggers", "0", "type"] and error.code == :invalid_value
             end)
    end

    test "validates callback_signal type for steps" do
      attrs = %{
        "name" => "example_workflow",
        "version" => "1.0.0",
        "steps" => [
          %{
            "name" => "ai_code_review",
            "type" => "agent",
            "agent" => "code_reviewer",
            "callback_signal" => 123
          }
        ]
      }

      assert {:error, errors} = Validator.validate(attrs)

      assert Enum.any?(errors, fn error ->
               error.path == ["steps", "0", "callback_signal"] and error.code == :invalid_type
             end)
    end
  end
end
