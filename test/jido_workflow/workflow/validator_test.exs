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

    test "rejects unknown top-level keys" do
      attrs = %{
        "name" => "unknown_top_level_key_flow",
        "version" => "1.0.0",
        "steps" => [],
        "unexpected" => true
      }

      assert {:error, errors} = Validator.validate(attrs)
      assert Enum.any?(errors, &(&1.path == ["unexpected"] and &1.code == :unknown_key))
    end

    test "rejects unknown signal-policy keys" do
      attrs = %{
        "name" => "unknown_signal_key_flow",
        "version" => "1.0.0",
        "signals" => %{
          "topic" => "workflow:unknown_signal_key_flow",
          "publish_events" => ["workflow_complete"],
          "unexpected_signal_key" => true
        },
        "steps" => []
      }

      assert {:error, errors} = Validator.validate(attrs)

      assert Enum.any?(errors, fn error ->
               error.path == ["signals", "unexpected_signal_key"] and error.code == :unknown_key
             end)
    end

    test "rejects unknown trigger keys" do
      attrs = %{
        "name" => "unknown_trigger_key_flow",
        "version" => "1.0.0",
        "triggers" => [
          %{
            "type" => "manual",
            "command" => "/workflow:unknown_trigger_key_flow",
            "unexpected_trigger_key" => true
          }
        ],
        "steps" => []
      }

      assert {:error, errors} = Validator.validate(attrs)

      assert Enum.any?(errors, fn error ->
               error.path == ["triggers", "0", "unexpected_trigger_key"] and
                 error.code == :unknown_key
             end)
    end

    test "rejects keys not allowed for signal triggers" do
      attrs = %{
        "name" => "invalid_signal_trigger_keys_flow",
        "version" => "1.0.0",
        "triggers" => [
          %{
            "type" => "signal",
            "patterns" => ["workflow.trigger.invalid_signal_trigger_keys_flow.requested"],
            "command" => "/workflow:invalid_signal_trigger_keys_flow"
          }
        ],
        "steps" => []
      }

      assert {:error, errors} = Validator.validate(attrs)

      assert Enum.any?(errors, fn error ->
               error.path == ["triggers", "0", "command"] and error.code == :unknown_key
             end)
    end

    test "requires patterns for signal triggers" do
      attrs = %{
        "name" => "missing_signal_patterns_flow",
        "version" => "1.0.0",
        "triggers" => [
          %{
            "type" => "signal"
          }
        ],
        "steps" => []
      }

      assert {:error, errors} = Validator.validate(attrs)

      assert Enum.any?(errors, fn error ->
               error.path == ["triggers", "0", "patterns"] and error.code == :required
             end)
    end

    test "requires schedule for scheduled triggers" do
      attrs = %{
        "name" => "missing_schedule_flow",
        "version" => "1.0.0",
        "triggers" => [
          %{
            "type" => "scheduled"
          }
        ],
        "steps" => []
      }

      assert {:error, errors} = Validator.validate(attrs)

      assert Enum.any?(errors, fn error ->
               error.path == ["triggers", "0", "schedule"] and error.code == :required
             end)
    end

    test "rejects unknown step keys" do
      attrs = %{
        "name" => "unknown_step_key_flow",
        "version" => "1.0.0",
        "steps" => [
          %{
            "name" => "parse_file",
            "type" => "action",
            "module" => "JidoCode.Actions.ParseElixirFile",
            "unexpected_step_key" => true
          }
        ]
      }

      assert {:error, errors} = Validator.validate(attrs)

      assert Enum.any?(errors, fn error ->
               error.path == ["steps", "0", "unexpected_step_key"] and error.code == :unknown_key
             end)
    end

    test "rejects agent-only keys on action steps" do
      attrs = %{
        "name" => "invalid_action_step_keys_flow",
        "version" => "1.0.0",
        "steps" => [
          %{
            "name" => "parse_file",
            "type" => "action",
            "module" => "JidoCode.Actions.ParseElixirFile",
            "mode" => "sync"
          }
        ]
      }

      assert {:error, errors} = Validator.validate(attrs)

      assert Enum.any?(errors, fn error ->
               error.path == ["steps", "0", "mode"] and error.code == :unknown_key
             end)
    end

    test "rejects action-only keys on agent steps" do
      attrs = %{
        "name" => "invalid_agent_step_keys_flow",
        "version" => "1.0.0",
        "steps" => [
          %{
            "name" => "ai_code_review",
            "type" => "agent",
            "agent" => "code_reviewer",
            "module" => "JidoCode.Actions.ParseElixirFile"
          }
        ]
      }

      assert {:error, errors} = Validator.validate(attrs)

      assert Enum.any?(errors, fn error ->
               error.path == ["steps", "0", "module"] and error.code == :unknown_key
             end)
    end

    test "rejects unknown settings keys" do
      attrs = %{
        "name" => "unknown_settings_key_flow",
        "version" => "1.0.0",
        "settings" => %{
          "max_concurrency" => 2,
          "unexpected_settings_key" => true
        },
        "steps" => []
      }

      assert {:error, errors} = Validator.validate(attrs)

      assert Enum.any?(errors, fn error ->
               error.path == ["settings", "unexpected_settings_key"] and
                 error.code == :unknown_key
             end)
    end

    test "rejects unknown retry_policy keys" do
      attrs = %{
        "name" => "unknown_retry_policy_key_flow",
        "version" => "1.0.0",
        "settings" => %{
          "retry_policy" => %{
            "max_retries" => 1,
            "unexpected_retry_policy_key" => true
          }
        },
        "steps" => []
      }

      assert {:error, errors} = Validator.validate(attrs)

      assert Enum.any?(errors, fn error ->
               error.path == ["settings", "retry_policy", "unexpected_retry_policy_key"] and
                 error.code == :unknown_key
             end)
    end

    test "rejects unknown input and return keys" do
      attrs = %{
        "name" => "unknown_input_return_key_flow",
        "version" => "1.0.0",
        "inputs" => [
          %{
            "name" => "file_path",
            "type" => "string",
            "unexpected_input_key" => true
          }
        ],
        "return" => %{
          "value" => "file_path",
          "unexpected_return_key" => true
        },
        "steps" => []
      }

      assert {:error, errors} = Validator.validate(attrs)

      assert Enum.any?(errors, fn error ->
               error.path == ["inputs", "0", "unexpected_input_key"] and
                 error.code == :unknown_key
             end)

      assert Enum.any?(errors, fn error ->
               error.path == ["return", "unexpected_return_key"] and error.code == :unknown_key
             end)
    end

    test "rejects unknown error_handler keys" do
      attrs = %{
        "name" => "unknown_error_handler_key_flow",
        "version" => "1.0.0",
        "error_handling" => [
          %{
            "handler" => "compensate:parse_file",
            "action" => "JidoWorkflow.TestActions.ParseFile",
            "unexpected_handler_key" => true
          }
        ],
        "steps" => []
      }

      assert {:error, errors} = Validator.validate(attrs)

      assert Enum.any?(errors, fn error ->
               error.path == ["error_handling", "0", "unexpected_handler_key"] and
                 error.code == :unknown_key
             end)
    end

    test "requires handler for error_handler entries" do
      attrs = %{
        "name" => "missing_error_handler_name_flow",
        "version" => "1.0.0",
        "error_handling" => [
          %{
            "action" => "JidoWorkflow.TestActions.ParseFile"
          }
        ],
        "steps" => []
      }

      assert {:error, errors} = Validator.validate(attrs)

      assert Enum.any?(errors, fn error ->
               error.path == ["error_handling", "0", "handler"] and error.code == :required
             end)
    end

    test "requires action for compensation handlers" do
      attrs = %{
        "name" => "missing_compensation_action_flow",
        "version" => "1.0.0",
        "error_handling" => [
          %{
            "handler" => "compensate:parse_file"
          }
        ],
        "steps" => []
      }

      assert {:error, errors} = Validator.validate(attrs)

      assert Enum.any?(errors, fn error ->
               error.path == ["error_handling", "0", "action"] and error.code == :required
             end)
    end

    test "validates inputs type for error_handler entries" do
      attrs = %{
        "name" => "invalid_error_handler_inputs_flow",
        "version" => "1.0.0",
        "error_handling" => [
          %{
            "handler" => "compensate:parse_file",
            "action" => "JidoWorkflow.TestActions.ParseFile",
            "inputs" => "invalid"
          }
        ],
        "steps" => []
      }

      assert {:error, errors} = Validator.validate(attrs)

      assert Enum.any?(errors, fn error ->
               error.path == ["error_handling", "0", "inputs"] and error.code == :invalid_type
             end)
    end
  end
end
