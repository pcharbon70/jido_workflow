defmodule JidoWorkflow.Workflow.SchemaValidatorTestCustomStep do
  use Jido.Action,
    name: "schema_validator_custom_step",
    schema: [
      step: [type: :map, required: true]
    ]

  @impl true
  def run(%{step: step}, _context), do: {:ok, step}
end

defmodule JidoWorkflow.Workflow.SchemaValidatorTestCustomTrigger do
  use GenServer

  @spec start_link(map()) :: GenServer.on_start()
  def start_link(config) do
    GenServer.start_link(__MODULE__, config)
  end

  @impl true
  def init(config), do: {:ok, config}
end

defmodule JidoWorkflow.Workflow.SchemaValidatorTest do
  use ExUnit.Case, async: false

  alias JidoWorkflow.Workflow.PluginExtensions
  alias JidoWorkflow.Workflow.SchemaValidator

  setup do
    original_step_types = Application.get_env(:jido_workflow, :workflow_step_types, %{})
    original_trigger_types = Application.get_env(:jido_workflow, :workflow_trigger_types, %{})

    on_exit(fn ->
      Application.put_env(:jido_workflow, :workflow_step_types, original_step_types)
      Application.put_env(:jido_workflow, :workflow_trigger_types, original_trigger_types)
    end)

    :ok
  end

  test "validate_workflow/1 accepts valid built-in workflow definitions" do
    attrs = %{
      "name" => "schema_valid_workflow",
      "version" => "1.0.0",
      "steps" => [
        %{
          "name" => "parse_file",
          "type" => "action",
          "module" => "JidoWorkflow.TestActions.ParseFile"
        }
      ]
    }

    assert :ok = SchemaValidator.validate_workflow(attrs)
  end

  test "validate_workflow/1 accepts signal publication policy fields" do
    attrs = %{
      "name" => "schema_signals_workflow",
      "version" => "1.0.0",
      "signals" => %{
        "topic" => "workflow:schema_signals",
        "publish_events" => ["step_started", "workflow_complete"]
      },
      "steps" => [
        %{
          "name" => "parse_file",
          "type" => "action",
          "module" => "JidoWorkflow.TestActions.ParseFile"
        }
      ]
    }

    assert :ok = SchemaValidator.validate_workflow(attrs)
  end

  test "validate_workflow/1 returns path-aware schema errors" do
    attrs = %{
      "name" => 123,
      "version" => "1.0.0",
      "steps" => []
    }

    assert {:error, errors} = SchemaValidator.validate_workflow(attrs)

    assert Enum.any?(errors, fn error ->
             error.path == ["name"]
           end)
  end

  test "validate_workflow/1 rejects keys not allowed for built-in step type schemas" do
    attrs = %{
      "name" => "schema_invalid_step_keys_workflow",
      "version" => "1.0.0",
      "steps" => [
        %{
          "name" => "parse_file",
          "type" => "action",
          "module" => "JidoWorkflow.TestActions.ParseFile",
          "mode" => "sync"
        }
      ]
    }

    assert {:error, errors} = SchemaValidator.validate_workflow(attrs)

    assert Enum.any?(errors, fn error ->
             error.path in [["steps", "0"], ["steps", "0", "mode"]]
           end)
  end

  test "validate_workflow/1 rejects keys not allowed for built-in trigger type schemas" do
    attrs = %{
      "name" => "schema_invalid_trigger_keys_workflow",
      "version" => "1.0.0",
      "triggers" => [
        %{
          "type" => "signal",
          "patterns" => ["workflow.schema.invalid_trigger_keys.requested"],
          "command" => "/workflow:schema_invalid_trigger_keys_workflow"
        }
      ],
      "steps" => []
    }

    assert {:error, errors} = SchemaValidator.validate_workflow(attrs)

    assert Enum.any?(errors, fn error ->
             error.path in [["triggers", "0"], ["triggers", "0", "command"]]
           end)
  end

  test "validate_workflow/1 enforces required trigger fields for built-in schemas" do
    attrs = %{
      "name" => "schema_missing_scheduled_trigger_field_workflow",
      "version" => "1.0.0",
      "triggers" => [
        %{
          "type" => "scheduled"
        }
      ],
      "steps" => []
    }

    assert {:error, errors} = SchemaValidator.validate_workflow(attrs)

    assert Enum.any?(errors, fn error ->
             error.path in [["triggers", "0"], ["triggers", "0", "schedule"]]
           end)
  end

  test "validate_workflow/1 enforces non-empty trigger pattern arrays for built-in schemas" do
    attrs = %{
      "name" => "schema_empty_trigger_patterns_workflow",
      "version" => "1.0.0",
      "triggers" => [
        %{
          "type" => "file_system",
          "patterns" => []
        },
        %{
          "type" => "signal",
          "patterns" => []
        }
      ],
      "steps" => []
    }

    assert {:error, errors} = SchemaValidator.validate_workflow(attrs)

    assert Enum.any?(errors, fn error ->
             error.path in [["triggers", "0"], ["triggers", "0", "patterns"]]
           end)

    assert Enum.any?(errors, fn error ->
             error.path in [["triggers", "1"], ["triggers", "1", "patterns"]]
           end)
  end

  test "validate_workflow/1 enforces non-empty trigger pattern entries for built-in schemas" do
    attrs = %{
      "name" => "schema_blank_trigger_pattern_entries_workflow",
      "version" => "1.0.0",
      "triggers" => [
        %{
          "type" => "file_system",
          "patterns" => [""]
        },
        %{
          "type" => "signal",
          "patterns" => [""]
        }
      ],
      "steps" => []
    }

    assert {:error, errors} = SchemaValidator.validate_workflow(attrs)

    assert Enum.any?(errors, fn error ->
             error.path in [
               ["triggers", "0"],
               ["triggers", "0", "patterns"],
               ["triggers", "0", "patterns", "0"]
             ]
           end)

    assert Enum.any?(errors, fn error ->
             error.path in [
               ["triggers", "1"],
               ["triggers", "1", "patterns"],
               ["triggers", "1", "patterns", "0"]
             ]
           end)
  end

  test "validate_workflow/1 rejects whitespace-only trigger pattern entries for built-in schemas" do
    attrs = %{
      "name" => "schema_whitespace_trigger_pattern_entries_workflow",
      "version" => "1.0.0",
      "triggers" => [
        %{
          "type" => "file_system",
          "patterns" => ["  "]
        },
        %{
          "type" => "signal",
          "patterns" => ["\t"]
        }
      ],
      "steps" => []
    }

    assert {:error, errors} = SchemaValidator.validate_workflow(attrs)

    assert Enum.any?(errors, fn error ->
             error.path in [
               ["triggers", "0"],
               ["triggers", "0", "patterns"],
               ["triggers", "0", "patterns", "0"]
             ]
           end)

    assert Enum.any?(errors, fn error ->
             error.path in [
               ["triggers", "1"],
               ["triggers", "1", "patterns"],
               ["triggers", "1", "patterns", "0"]
             ]
           end)
  end

  test "validate_workflow/1 enforces non-empty schedule for scheduled triggers" do
    attrs = %{
      "name" => "schema_empty_trigger_schedule_workflow",
      "version" => "1.0.0",
      "triggers" => [
        %{
          "type" => "scheduled",
          "schedule" => ""
        }
      ],
      "steps" => []
    }

    assert {:error, errors} = SchemaValidator.validate_workflow(attrs)

    assert Enum.any?(errors, fn error ->
             error.path in [["triggers", "0"], ["triggers", "0", "schedule"]]
           end)
  end

  test "validate_workflow/1 rejects whitespace-only scheduled and manual trigger strings" do
    attrs = %{
      "name" => "schema_whitespace_trigger_strings_workflow",
      "version" => "1.0.0",
      "triggers" => [
        %{
          "type" => "scheduled",
          "schedule" => "   "
        },
        %{
          "type" => "manual",
          "command" => "\t"
        }
      ],
      "steps" => []
    }

    assert {:error, errors} = SchemaValidator.validate_workflow(attrs)

    assert Enum.any?(errors, fn error ->
             error.path in [
               ["triggers", "0"],
               ["triggers", "0", "schedule"]
             ]
           end)

    assert Enum.any?(errors, fn error ->
             error.path in [
               ["triggers", "1"],
               ["triggers", "1", "command"]
             ]
           end)
  end

  test "validate_workflow/1 enforces non-empty compensation action names" do
    attrs = %{
      "name" => "schema_empty_compensation_action_workflow",
      "version" => "1.0.0",
      "error_handling" => [
        %{
          "handler" => "compensate:parse_file",
          "action" => ""
        }
      ],
      "steps" => []
    }

    assert {:error, errors} = SchemaValidator.validate_workflow(attrs)

    assert Enum.any?(errors, fn error ->
             error.path in [["error_handling", "0"], ["error_handling", "0", "action"]]
           end)
  end

  test "validate_workflow/1 enforces non-empty required step target strings" do
    attrs = %{
      "name" => "schema_empty_step_target_workflow",
      "version" => "1.0.0",
      "steps" => [
        %{
          "name" => "parse_file",
          "type" => "action",
          "module" => ""
        }
      ]
    }

    assert {:error, errors} = SchemaValidator.validate_workflow(attrs)

    assert Enum.any?(errors, fn error ->
             error.path in [["steps", "0"], ["steps", "0", "module"]]
           end)
  end

  test "validate_workflow/1 enforces built-in trigger event values" do
    attrs = %{
      "name" => "schema_invalid_trigger_events_workflow",
      "version" => "1.0.0",
      "triggers" => [
        %{
          "type" => "file_system",
          "patterns" => ["lib/**/*.ex"],
          "events" => ["pre_commit"]
        },
        %{
          "type" => "git_hook",
          "events" => ["pre_commit"]
        }
      ],
      "steps" => []
    }

    assert {:error, errors} = SchemaValidator.validate_workflow(attrs)

    assert Enum.any?(errors, fn error ->
             error.path in [
               ["triggers", "0"],
               ["triggers", "0", "events"],
               ["triggers", "0", "events", "0"]
             ]
           end)

    assert Enum.any?(errors, fn error ->
             error.path in [
               ["triggers", "1"],
               ["triggers", "1", "events"],
               ["triggers", "1", "events", "0"]
             ]
           end)
  end

  test "validate_workflow/1 rejects unknown keys for error_handler entries" do
    attrs = %{
      "name" => "schema_invalid_error_handler_keys_workflow",
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

    assert {:error, errors} = SchemaValidator.validate_workflow(attrs)

    assert Enum.any?(errors, fn error ->
             error.path in [
               ["error_handling", "0"],
               ["error_handling", "0", "unexpected_handler_key"]
             ]
           end)
  end

  test "validate_workflow/1 enforces action for compensation handlers" do
    attrs = %{
      "name" => "schema_missing_compensation_action_workflow",
      "version" => "1.0.0",
      "error_handling" => [
        %{
          "handler" => "compensate:parse_file"
        }
      ],
      "steps" => []
    }

    assert {:error, errors} = SchemaValidator.validate_workflow(attrs)

    assert Enum.any?(errors, fn error ->
             error.path in [["error_handling", "0"], ["error_handling", "0", "action"]]
           end)
  end

  test "validate_workflow/1 enforces input default type compatibility" do
    attrs = %{
      "name" => "schema_invalid_input_default_type_workflow",
      "version" => "1.0.0",
      "inputs" => [
        %{
          "name" => "retry_count",
          "type" => "integer",
          "default" => "3"
        }
      ],
      "steps" => []
    }

    assert {:error, errors} = SchemaValidator.validate_workflow(attrs)

    assert Enum.any?(errors, fn error ->
             error.path in [["inputs", "0"], ["inputs", "0", "default"]]
           end)
  end

  test "validate_workflow/1 enforces numeric minimums for trigger, step, and retry fields" do
    attrs = %{
      "name" => "schema_invalid_numeric_minimums_workflow",
      "version" => "1.0.0",
      "triggers" => [
        %{
          "type" => "file_system",
          "patterns" => ["lib/**/*.ex"],
          "debounce_ms" => -1
        }
      ],
      "settings" => %{
        "retry_policy" => %{
          "max_retries" => 1,
          "backoff" => "constant",
          "base_delay_ms" => -10
        }
      },
      "steps" => [
        %{
          "name" => "parse_file",
          "type" => "action",
          "module" => "JidoWorkflow.TestActions.ParseFile",
          "timeout_ms" => 0,
          "max_retries" => -1
        }
      ]
    }

    assert {:error, errors} = SchemaValidator.validate_workflow(attrs)

    assert Enum.any?(errors, fn error ->
             error.path in [["triggers", "0"], ["triggers", "0", "debounce_ms"]]
           end)

    assert Enum.any?(errors, fn error ->
             error.path in [
               ["settings"],
               ["settings", "retry_policy"],
               ["settings", "retry_policy", "base_delay_ms"]
             ]
           end)

    assert Enum.any?(errors, fn error ->
             error.path in [["steps", "0"], ["steps", "0", "timeout_ms"]]
           end)

    assert Enum.any?(errors, fn error ->
             error.path in [["steps", "0"], ["steps", "0", "max_retries"]]
           end)
  end

  test "validate_workflow/1 supports custom plugin step types" do
    assert :ok =
             PluginExtensions.register_step_type(
               "custom_step",
               JidoWorkflow.Workflow.SchemaValidatorTestCustomStep
             )

    attrs = %{
      "name" => "schema_custom_step_workflow",
      "version" => "1.0.0",
      "steps" => [
        %{"name" => "custom_one", "type" => "custom_step"}
      ]
    }

    assert :ok = SchemaValidator.validate_workflow(attrs)
  end

  test "validate_workflow/1 supports custom plugin trigger types" do
    assert :ok =
             PluginExtensions.register_trigger_type(
               "webhook",
               JidoWorkflow.Workflow.SchemaValidatorTestCustomTrigger
             )

    attrs = %{
      "name" => "schema_custom_trigger_workflow",
      "version" => "1.0.0",
      "triggers" => [
        %{"type" => "webhook"}
      ],
      "steps" => []
    }

    assert :ok = SchemaValidator.validate_workflow(attrs)
  end

  test "validate_triggers_config/1 supports custom plugin trigger types" do
    assert :ok =
             PluginExtensions.register_trigger_type(
               "webhook",
               JidoWorkflow.Workflow.SchemaValidatorTestCustomTrigger
             )

    attrs = %{
      "triggers" => [
        %{"id" => "trigger:webhook:1", "workflow_id" => "schema_flow", "type" => "webhook"}
      ]
    }

    assert :ok = SchemaValidator.validate_triggers_config(attrs)
  end

  test "validate_triggers_config/1 returns path-aware errors" do
    attrs = %{
      "triggers" => [
        %{"id" => "trigger:invalid:1", "workflow_id" => "schema_flow", "type" => 123}
      ]
    }

    assert {:error, errors} = SchemaValidator.validate_triggers_config(attrs)

    assert Enum.any?(errors, fn error ->
             error.path == ["triggers", "0", "type"]
           end)
  end

  test "validate_triggers_config/1 rejects unknown top-level keys" do
    attrs = %{
      "triggers" => [],
      "unexpected" => true
    }

    assert {:error, errors} = SchemaValidator.validate_triggers_config(attrs)

    assert Enum.any?(errors, fn error ->
             error.path in [[], ["unexpected"]]
           end)
  end

  test "validate_triggers_config/1 rejects unsupported config keys for built-in trigger types" do
    attrs = %{
      "triggers" => [
        %{
          "id" => "trigger:signal:invalid_config",
          "workflow_id" => "schema_flow",
          "type" => "signal",
          "config" => %{
            "patterns" => ["workflow.schema.signal.requested"],
            "schedule" => "*/5 * * * *"
          }
        }
      ]
    }

    assert {:error, errors} = SchemaValidator.validate_triggers_config(attrs)

    assert Enum.any?(errors, fn error ->
             error.path in [
               ["triggers", "0"],
               ["triggers", "0", "config"],
               ["triggers", "0", "config", "schedule"]
             ]
           end)
  end

  test "validate_triggers_config/1 enforces required config fields for built-in trigger types" do
    attrs = %{
      "triggers" => [
        %{
          "id" => "trigger:scheduled:missing_schedule",
          "workflow_id" => "schema_flow",
          "type" => "scheduled",
          "config" => %{}
        }
      ]
    }

    assert {:error, errors} = SchemaValidator.validate_triggers_config(attrs)

    assert Enum.any?(errors, fn error ->
             error.path in [
               ["triggers", "0"],
               ["triggers", "0", "config"],
               ["triggers", "0", "config", "schedule"]
             ]
           end)
  end

  test "validate_triggers_config/1 enforces non-empty trigger identifiers and schedule strings" do
    attrs = %{
      "triggers" => [
        %{
          "id" => "",
          "workflow_id" => "schema_flow",
          "type" => "manual"
        },
        %{
          "id" => "trigger:scheduled:empty_schedule",
          "workflow_id" => "",
          "type" => "scheduled",
          "config" => %{"schedule" => ""}
        }
      ]
    }

    assert {:error, errors} = SchemaValidator.validate_triggers_config(attrs)

    assert Enum.any?(errors, fn error ->
             error.path in [["triggers", "0"], ["triggers", "0", "id"]]
           end)

    assert Enum.any?(errors, fn error ->
             error.path in [["triggers", "1"], ["triggers", "1", "workflow_id"]]
           end)

    assert Enum.any?(errors, fn error ->
             error.path in [
               ["triggers", "1"],
               ["triggers", "1", "config"],
               ["triggers", "1", "config", "schedule"]
             ]
           end)
  end

  test "validate_triggers_config/1 rejects whitespace-only identifiers and schedule or command strings" do
    attrs = %{
      "triggers" => [
        %{
          "id" => " ",
          "workflow_id" => "schema_flow",
          "type" => "manual",
          "config" => %{"command" => "\t"}
        },
        %{
          "id" => "trigger:scheduled:whitespace_schedule",
          "workflow_id" => " ",
          "type" => "scheduled",
          "config" => %{"schedule" => "   "}
        }
      ]
    }

    assert {:error, errors} = SchemaValidator.validate_triggers_config(attrs)

    assert Enum.any?(errors, fn error ->
             error.path in [["triggers", "0"], ["triggers", "0", "id"]]
           end)

    assert Enum.any?(errors, fn error ->
             error.path in [
               ["triggers", "0"],
               ["triggers", "0", "config"],
               ["triggers", "0", "config", "command"]
             ]
           end)

    assert Enum.any?(errors, fn error ->
             error.path in [["triggers", "1"], ["triggers", "1", "workflow_id"]]
           end)

    assert Enum.any?(errors, fn error ->
             error.path in [
               ["triggers", "1"],
               ["triggers", "1", "config"],
               ["triggers", "1", "config", "schedule"]
             ]
           end)
  end

  test "validate_triggers_config/1 enforces non-empty trigger pattern arrays and entries" do
    attrs = %{
      "triggers" => [
        %{
          "id" => "trigger:file_system:empty_patterns",
          "workflow_id" => "schema_flow",
          "type" => "file_system",
          "config" => %{
            "patterns" => []
          }
        },
        %{
          "id" => "trigger:signal:blank_pattern",
          "workflow_id" => "schema_flow",
          "type" => "signal",
          "config" => %{
            "patterns" => [""]
          }
        }
      ]
    }

    assert {:error, errors} = SchemaValidator.validate_triggers_config(attrs)

    assert Enum.any?(errors, fn error ->
             error.path in [
               ["triggers", "0"],
               ["triggers", "0", "config"],
               ["triggers", "0", "config", "patterns"]
             ]
           end)

    assert Enum.any?(errors, fn error ->
             error.path in [
               ["triggers", "1"],
               ["triggers", "1", "config"],
               ["triggers", "1", "config", "patterns"],
               ["triggers", "1", "config", "patterns", "0"]
             ]
           end)
  end

  test "validate_triggers_config/1 rejects whitespace-only trigger pattern entries" do
    attrs = %{
      "triggers" => [
        %{
          "id" => "trigger:file_system:whitespace_pattern",
          "workflow_id" => "schema_flow",
          "type" => "file_system",
          "config" => %{
            "patterns" => [" "]
          }
        },
        %{
          "id" => "trigger:signal:whitespace_pattern",
          "workflow_id" => "schema_flow",
          "type" => "signal",
          "config" => %{
            "patterns" => ["\t"]
          }
        }
      ]
    }

    assert {:error, errors} = SchemaValidator.validate_triggers_config(attrs)

    assert Enum.any?(errors, fn error ->
             error.path in [
               ["triggers", "0"],
               ["triggers", "0", "config"],
               ["triggers", "0", "config", "patterns"],
               ["triggers", "0", "config", "patterns", "0"]
             ]
           end)

    assert Enum.any?(errors, fn error ->
             error.path in [
               ["triggers", "1"],
               ["triggers", "1", "config"],
               ["triggers", "1", "config", "patterns"],
               ["triggers", "1", "config", "patterns", "0"]
             ]
           end)
  end

  test "validate_triggers_config/1 enforces built-in trigger config event values" do
    attrs = %{
      "triggers" => [
        %{
          "id" => "trigger:file_system:invalid_events",
          "workflow_id" => "schema_flow",
          "type" => "file_system",
          "config" => %{
            "patterns" => ["lib/**/*.ex"],
            "events" => ["pre_commit"]
          }
        },
        %{
          "id" => "trigger:git_hook:invalid_events",
          "workflow_id" => "schema_flow",
          "type" => "git_hook",
          "config" => %{
            "events" => ["pre_commit"]
          }
        }
      ]
    }

    assert {:error, errors} = SchemaValidator.validate_triggers_config(attrs)

    assert Enum.any?(errors, fn error ->
             error.path in [
               ["triggers", "0"],
               ["triggers", "0", "config"],
               ["triggers", "0", "config", "events"],
               ["triggers", "0", "config", "events", "0"]
             ]
           end)

    assert Enum.any?(errors, fn error ->
             error.path in [
               ["triggers", "1"],
               ["triggers", "1", "config"],
               ["triggers", "1", "config", "events"],
               ["triggers", "1", "config", "events", "0"]
             ]
           end)
  end

  test "validate_workflow_config/1 accepts valid top-level config" do
    attrs = %{
      "workflow_dir" => ".jido_code/workflows",
      "triggers_config_path" => ".jido_code/workflows/triggers.json",
      "trigger_sync_interval_ms" => 2500,
      "trigger_backend" => "strategy",
      "engine_backend" => "strategy"
    }

    assert :ok = SchemaValidator.validate_workflow_config(attrs)
  end

  test "validate_workflow_config/1 accepts valid nested workflow config" do
    attrs = %{
      "workflow" => %{
        "workflow_dir" => ".jido_code/workflows",
        "triggers_config_path" => ".jido_code/workflows/triggers.json",
        "trigger_sync_interval_ms" => 1000,
        "trigger_backend" => "direct",
        "engine_backend" => "strategy"
      }
    }

    assert :ok = SchemaValidator.validate_workflow_config(attrs)
  end

  test "validate_workflow_config/1 returns path-aware errors" do
    attrs = %{
      "workflow_dir" => "",
      "trigger_sync_interval_ms" => 0,
      "trigger_backend" => "invalid",
      "engine_backend" => "invalid"
    }

    assert {:error, errors} = SchemaValidator.validate_workflow_config(attrs)

    assert Enum.any?(errors, fn error ->
             error.path == ["workflow_dir"]
           end)

    assert Enum.any?(errors, fn error ->
             error.path == ["trigger_sync_interval_ms"]
           end)

    assert Enum.any?(errors, fn error ->
             error.path == ["trigger_backend"]
           end)

    assert Enum.any?(errors, fn error ->
             error.path == ["engine_backend"]
           end)
  end
end
