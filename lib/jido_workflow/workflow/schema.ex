defmodule JidoWorkflow.Workflow.Schema do
  @moduledoc """
  Loads and normalizes JSON schemas used by workflow configuration.

  The loaded schemas are adjusted at runtime so allowed workflow step and trigger
  types stay in sync with the registries, including plugin-registered types.
  """

  alias JidoWorkflow.Workflow.StepTypeRegistry
  alias JidoWorkflow.Workflow.TriggerTypeRegistry

  @workflow_definition_schema_path "priv/schemas/workflow_definition.schema.json"
  @triggers_schema_path "priv/schemas/triggers.schema.json"
  @workflow_config_schema_path "priv/schemas/workflow_config.schema.json"

  @builtin_step_definitions %{
    "action" => "action_step",
    "agent" => "agent_step",
    "skill" => "skill_step",
    "sub_workflow" => "sub_workflow_step"
  }
  @builtin_trigger_definitions %{
    "file_system" => "file_system_trigger",
    "git_hook" => "git_hook_trigger",
    "signal" => "signal_trigger",
    "scheduled" => "scheduled_trigger",
    "manual" => "manual_trigger"
  }

  @type schema :: map()

  @spec workflow_definition() :: {:ok, schema()} | {:error, term()}
  def workflow_definition do
    with {:ok, schema} <- load_schema(@workflow_definition_schema_path) do
      trigger_types = TriggerTypeRegistry.supported_types()
      step_types = StepTypeRegistry.supported_types()
      builtin_step_types = builtin_step_types()
      builtin_one_of = builtin_step_one_of(schema, builtin_step_types)
      builtin_trigger_types = builtin_trigger_types()
      builtin_trigger_one_of = builtin_trigger_one_of(schema, builtin_trigger_types)

      plugin_step_ref = [%{"$ref" => "#/definitions/plugin_step"}]
      plugin_trigger_ref = [%{"$ref" => "#/definitions/plugin_trigger"}]

      step_definition =
        schema
        |> get_in_path(["definitions", "step"], %{})
        |> ensure_map()
        |> put_in_path(["properties", "type"], %{"enum" => step_types})
        |> Map.put("oneOf", builtin_one_of ++ plugin_step_ref)

      trigger_definition =
        schema
        |> get_in_path(["definitions", "trigger"], %{})
        |> ensure_map()
        |> put_in_path(["properties", "type"], %{"enum" => trigger_types})
        |> Map.put("oneOf", builtin_trigger_one_of ++ plugin_trigger_ref)

      workflow_schema =
        schema
        |> put_in_path(["definitions", "step"], step_definition)
        |> put_in_path(["definitions", "plugin_step"], plugin_step_definition(builtin_step_types))
        |> put_in_path(["definitions", "trigger"], trigger_definition)
        |> put_in_path(
          ["definitions", "plugin_trigger"],
          plugin_trigger_definition(builtin_trigger_types)
        )

      {:ok, workflow_schema}
    end
  end

  @spec triggers_config() :: {:ok, schema()} | {:error, term()}
  def triggers_config do
    with {:ok, schema} <- load_schema(@triggers_schema_path) do
      trigger_types = TriggerTypeRegistry.supported_types()

      {:ok,
       put_in_path(
         schema,
         ["properties", "triggers", "items", "properties", "type"],
         %{"enum" => trigger_types}
       )}
    end
  end

  @spec workflow_config() :: {:ok, schema()} | {:error, term()}
  def workflow_config do
    load_schema(@workflow_config_schema_path)
  end

  defp load_schema(relative_path) do
    path = Application.app_dir(:jido_workflow, relative_path)

    with {:ok, contents} <- File.read(path),
         {:ok, decoded} <- Jason.decode(contents) do
      {:ok, decoded}
    else
      {:error, reason} -> {:error, {:schema_load_failed, path, reason}}
    end
  end

  defp builtin_step_types do
    StepTypeRegistry.all()
    |> Enum.flat_map(fn
      {type, {:builtin, _kind}} -> [type]
      _other -> []
    end)
    |> Enum.sort()
  end

  defp builtin_step_one_of(schema, builtin_step_types) do
    builtin_step_types
    |> Enum.map(&Map.get(@builtin_step_definitions, &1))
    |> Enum.reject(&is_nil/1)
    |> Enum.filter(fn definition_name ->
      is_map(get_in_path(schema, ["definitions", definition_name], nil))
    end)
    |> Enum.map(fn definition_name ->
      %{"$ref" => "#/definitions/#{definition_name}"}
    end)
  end

  defp builtin_trigger_types do
    TriggerTypeRegistry.supported_types()
    |> Enum.filter(&Map.has_key?(@builtin_trigger_definitions, &1))
    |> Enum.sort()
  end

  defp builtin_trigger_one_of(schema, builtin_trigger_types) do
    builtin_trigger_types
    |> Enum.map(&Map.get(@builtin_trigger_definitions, &1))
    |> Enum.reject(&is_nil/1)
    |> Enum.filter(fn definition_name ->
      is_map(get_in_path(schema, ["definitions", definition_name], nil))
    end)
    |> Enum.map(fn definition_name ->
      %{"$ref" => "#/definitions/#{definition_name}"}
    end)
  end

  defp plugin_step_definition([]) do
    %{
      "type" => "object",
      "required" => ["name", "type"],
      "properties" => %{
        "name" => %{"type" => "string"},
        "type" => %{"type" => "string"}
      }
    }
  end

  defp plugin_step_definition(builtin_step_types) do
    %{
      "type" => "object",
      "required" => ["name", "type"],
      "properties" => %{
        "name" => %{"type" => "string"},
        "type" => %{"type" => "string", "not" => %{"enum" => builtin_step_types}}
      }
    }
  end

  defp plugin_trigger_definition([]) do
    %{
      "type" => "object",
      "required" => ["type"],
      "properties" => %{
        "type" => %{"type" => "string"}
      }
    }
  end

  defp plugin_trigger_definition(builtin_trigger_types) do
    %{
      "type" => "object",
      "required" => ["type"],
      "properties" => %{
        "type" => %{"type" => "string", "not" => %{"enum" => builtin_trigger_types}}
      }
    }
  end

  defp get_in_path(value, [], default), do: if(is_nil(value), do: default, else: value)

  defp get_in_path(value, [key | rest], default) when is_map(value) do
    value
    |> Map.get(key)
    |> get_in_path(rest, default)
  end

  defp get_in_path(_value, _path, default), do: default

  defp put_in_path(map, [key], value) do
    map
    |> ensure_map()
    |> Map.put(key, value)
  end

  defp put_in_path(map, [key | rest], value) do
    map = ensure_map(map)
    nested = map |> Map.get(key) |> put_in_path(rest, value)
    Map.put(map, key, nested)
  end

  defp ensure_map(value) when is_map(value), do: value
  defp ensure_map(_value), do: %{}
end
