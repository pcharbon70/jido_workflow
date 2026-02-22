defmodule Jido.Code.Workflow.SchemaValidator do
  @moduledoc """
  Validates workflow and trigger configuration maps against JSON schemas.

  Errors are normalized into `Jido.Code.Workflow.ValidationError` values.
  """

  alias Jido.Code.Workflow.Schema
  alias Jido.Code.Workflow.ValidationError

  @type validation_result :: :ok | {:error, [ValidationError.t()]}

  @spec validate_workflow(map()) :: validation_result()
  def validate_workflow(attrs) when is_map(attrs) do
    validate(attrs, &Schema.workflow_definition/0, "workflow definition")
  end

  def validate_workflow(other) do
    {:error,
     [
       %ValidationError{
         path: [],
         code: :invalid_type,
         message: "workflow definition must be a map, got: #{inspect(other)}"
       }
     ]}
  end

  @spec validate_triggers_config(map()) :: validation_result()
  def validate_triggers_config(attrs) when is_map(attrs) do
    validate(attrs, &Schema.triggers_config/0, "triggers configuration")
  end

  def validate_triggers_config(other) do
    {:error,
     [
       %ValidationError{
         path: [],
         code: :invalid_type,
         message: "triggers configuration must be a map, got: #{inspect(other)}"
       }
     ]}
  end

  @spec validate_workflow_config(map()) :: validation_result()
  def validate_workflow_config(attrs) when is_map(attrs) do
    validate(attrs, &Schema.workflow_config/0, "workflow configuration")
  end

  def validate_workflow_config(other) do
    {:error,
     [
       %ValidationError{
         path: [],
         code: :invalid_type,
         message: "workflow configuration must be a map, got: #{inspect(other)}"
       }
     ]}
  end

  defp validate(attrs, schema_fun, subject_name) do
    sanitized_attrs = compact_nils(attrs)

    with {:ok, schema} <- schema_fun.(),
         {:ok, root} <- JSV.build(schema),
         {:ok, _validated} <- JSV.validate(sanitized_attrs, root) do
      :ok
    else
      {:error, %JSV.ValidationError{} = validation_error} ->
        {:error, normalize_validation_error(validation_error, subject_name)}

      {:error, reason} ->
        {:error,
         [
           %ValidationError{
             path: [],
             code: :schema_validation_failed,
             message: "failed to validate #{subject_name} schema: #{format_reason(reason)}"
           }
         ]}
    end
  end

  defp normalize_validation_error(validation_error, subject_name) do
    validation_error
    |> JSV.normalize_error()
    |> collect_entries()
    |> Enum.uniq_by(fn %ValidationError{path: path, code: code, message: message} ->
      {path, code, message}
    end)
    |> case do
      [] ->
        [
          %ValidationError{
            path: [],
            code: :invalid_schema,
            message: "#{subject_name} does not satisfy the configured schema"
          }
        ]

      entries ->
        entries
    end
  end

  defp collect_entries(node) when is_map(node) do
    direct_entries =
      node
      |> fetch_any("errors")
      |> case do
        errors when is_list(errors) ->
          location = fetch_any(node, "instanceLocation") || "#"

          Enum.map(errors, fn error ->
            %ValidationError{
              path: path_from_pointer(location),
              code: normalize_code(fetch_any(error, "kind")),
              message: normalize_message(fetch_any(error, "message"))
            }
          end)

        _other ->
          []
      end

    nested_entries =
      node
      |> fetch_any("details")
      |> case do
        details when is_list(details) ->
          Enum.flat_map(details, &collect_entries/1)

        _other ->
          []
      end

    direct_entries ++ nested_entries
  end

  defp collect_entries(_other), do: []

  defp path_from_pointer(pointer) when pointer in [nil, "", "#"], do: []

  defp path_from_pointer(pointer) when is_binary(pointer) do
    pointer
    |> String.trim()
    |> String.trim_leading("#")
    |> String.trim_leading("/")
    |> case do
      "" ->
        []

      value ->
        value
        |> String.split("/")
        |> Enum.map(fn segment ->
          segment
          |> String.replace("~1", "/")
          |> String.replace("~0", "~")
        end)
    end
  end

  defp path_from_pointer(_other), do: []

  defp normalize_code(code) when is_atom(code), do: code
  defp normalize_code(_code), do: :invalid_schema

  defp normalize_message(message) when is_binary(message), do: message
  defp normalize_message(message), do: inspect(message)

  defp format_reason(reason) when is_exception(reason), do: Exception.message(reason)
  defp format_reason(reason), do: inspect(reason)

  defp fetch_any(value, _key) when not is_map(value), do: nil

  defp fetch_any(value, key) do
    string_key = to_string(key)
    Map.get(value, key) || Map.get(value, string_key) || fetch_atom_key(value, string_key)
  end

  defp fetch_atom_key(value, string_key) do
    Enum.find_value(value, fn
      {map_key, map_value} when is_atom(map_key) ->
        if Atom.to_string(map_key) == string_key, do: map_value

      _other ->
        nil
    end)
  end

  defp compact_nils(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, item}, acc ->
      compacted = compact_nils(item)

      if is_nil(compacted) do
        acc
      else
        Map.put(acc, key, compacted)
      end
    end)
  end

  defp compact_nils(value) when is_list(value), do: Enum.map(value, &compact_nils/1)
  defp compact_nils(value), do: value
end
