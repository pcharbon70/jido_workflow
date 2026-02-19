defmodule JidoWorkflow.Workflow.TriggerConfig do
  @moduledoc """
  Loads and validates global trigger configuration files.

  Trigger files are JSON documents matching `priv/schemas/triggers.schema.json`.
  """

  alias JidoWorkflow.Workflow.SchemaValidator
  alias JidoWorkflow.Workflow.ValidationError

  @type global_settings :: %{
          optional(:default_debounce_ms) => non_neg_integer(),
          optional(:max_concurrent_triggers) => pos_integer()
        }

  @type trigger_entry :: map()
  @type document :: %{global_settings: global_settings(), triggers: [trigger_entry()]}
  @type result :: {:ok, [trigger_entry()]} | {:error, [ValidationError.t()]}
  @type document_result :: {:ok, document()} | {:error, [ValidationError.t()]}

  @spec load_file(Path.t() | nil) :: result()
  def load_file(path) do
    case load_document(path) do
      {:ok, %{triggers: triggers}} -> {:ok, triggers}
      {:error, errors} -> {:error, errors}
    end
  end

  @spec load_document(Path.t() | nil) :: document_result()
  def load_document(nil), do: {:ok, empty_document()}

  def load_document(path) when is_binary(path) do
    expanded = Path.expand(path)

    if File.exists?(expanded) do
      with {:ok, contents} <- File.read(expanded),
           {:ok, decoded} <- Jason.decode(contents),
           :ok <- SchemaValidator.validate_triggers_config(decoded) do
        {:ok, normalize_document(decoded)}
      else
        {:error, errors} when is_list(errors) ->
          {:error, errors}

        {:error, reason} ->
          {:error, [error(["triggers_file"], :invalid_config, format_reason(reason))]}
      end
    else
      {:ok, empty_document()}
    end
  end

  def load_document(other) do
    {:error,
     [
       error(
         ["triggers_file"],
         :invalid_type,
         "trigger config path must be a string, got: #{inspect(other)}"
       )
     ]}
  end

  defp normalize_document(document) do
    %{
      global_settings: document |> fetch("global_settings") |> normalize_global_settings(),
      triggers: document |> fetch("triggers") |> normalize_triggers()
    }
  end

  defp empty_document do
    %{global_settings: %{}, triggers: []}
  end

  defp normalize_global_settings(settings) when is_map(settings) do
    %{}
    |> maybe_put_setting(
      :default_debounce_ms,
      normalize_non_neg_integer(fetch(settings, "default_debounce_ms"))
    )
    |> maybe_put_setting(
      :max_concurrent_triggers,
      normalize_positive_integer(fetch(settings, "max_concurrent_triggers"))
    )
  end

  defp normalize_global_settings(_other), do: %{}

  defp maybe_put_setting(settings, _key, nil), do: settings
  defp maybe_put_setting(settings, key, value), do: Map.put(settings, key, value)

  defp normalize_non_neg_integer(value) when is_integer(value) and value >= 0, do: value
  defp normalize_non_neg_integer(_value), do: nil

  defp normalize_positive_integer(value) when is_integer(value) and value > 0, do: value
  defp normalize_positive_integer(_value), do: nil

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
    case Map.fetch(map, key) do
      {:ok, value} ->
        value

      :error ->
        fetch_atom_key(map, key)
    end
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
