defmodule JidoWorkflow.Workflow.TriggerConfig do
  @moduledoc """
  Loads and validates global trigger configuration files.

  Trigger files are JSON documents matching `priv/schemas/triggers.schema.json`.
  """

  alias JidoWorkflow.Workflow.SchemaValidator
  alias JidoWorkflow.Workflow.ValidationError

  @type trigger_entry :: map()
  @type result :: {:ok, [trigger_entry()]} | {:error, [ValidationError.t()]}

  @spec load_file(Path.t() | nil) :: result()
  def load_file(nil), do: {:ok, []}

  def load_file(path) when is_binary(path) do
    expanded = Path.expand(path)

    if File.exists?(expanded) do
      with {:ok, contents} <- File.read(expanded),
           {:ok, decoded} <- Jason.decode(contents),
           :ok <- SchemaValidator.validate_triggers_config(decoded) do
        {:ok, decoded |> fetch("triggers") |> normalize_triggers()}
      else
        {:error, errors} when is_list(errors) ->
          {:error, errors}

        {:error, reason} ->
          {:error, [error(["triggers_file"], :invalid_config, format_reason(reason))]}
      end
    else
      {:ok, []}
    end
  end

  def load_file(other) do
    {:error,
     [
       error(
         ["triggers_file"],
         :invalid_type,
         "trigger config path must be a string, got: #{inspect(other)}"
       )
     ]}
  end

  defp normalize_triggers(list) when is_list(list) do
    Enum.map(list, &normalize_trigger/1)
  end

  defp normalize_triggers(_other), do: []

  defp normalize_trigger(trigger) when is_map(trigger) do
    config =
      trigger
      |> fetch("config")
      |> normalize_config_map()

    config
    |> Map.put(:id, fetch(trigger, "id"))
    |> Map.put(:workflow_id, fetch(trigger, "workflow_id"))
    |> Map.put(:type, fetch(trigger, "type"))
    |> Map.put(:enabled, normalize_enabled(fetch(trigger, "enabled")))
  end

  defp normalize_trigger(_other), do: %{}

  defp normalize_config_map(config) when is_map(config), do: stringify_keys(config)
  defp normalize_config_map(_other), do: %{}

  defp normalize_enabled(false), do: false
  defp normalize_enabled(_value), do: true

  defp fetch(map, key) when is_map(map) do
    Map.get(map, key) || fetch_atom_key(map, key)
  end

  defp fetch_atom_key(map, key) do
    Enum.find_value(map, fn
      {map_key, map_value} when is_atom(map_key) ->
        if Atom.to_string(map_key) == key, do: map_value

      _other ->
        nil
    end)
  end

  defp stringify_keys(value) when is_map(value) do
    Enum.into(value, %{}, fn {key, item} ->
      {to_string(key), stringify_keys(item)}
    end)
  end

  defp stringify_keys(value) when is_list(value), do: Enum.map(value, &stringify_keys/1)
  defp stringify_keys(value), do: value

  defp format_reason(%Jason.DecodeError{} = error), do: Exception.message(error)
  defp format_reason(reason), do: inspect(reason)

  defp error(path, code, message), do: %ValidationError{path: path, code: code, message: message}
end
