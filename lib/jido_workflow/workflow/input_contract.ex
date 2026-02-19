defmodule JidoWorkflow.Workflow.InputContract do
  @moduledoc """
  Applies workflow input contracts to runtime input maps.
  """

  alias JidoWorkflow.Workflow.Definition.Input, as: DefinitionInput
  alias JidoWorkflow.Workflow.ValidationError

  @type schema_input :: %{
          name: String.t(),
          type: String.t(),
          required: boolean(),
          default: term(),
          description: String.t() | nil
        }

  @type schema :: [schema_input()]

  @spec compile_schema([DefinitionInput.t()] | nil) :: schema()
  def compile_schema(nil), do: []

  def compile_schema(inputs) when is_list(inputs) do
    Enum.map(inputs, &serialize_input/1)
  end

  def compile_schema(_other), do: []

  @spec normalize_inputs(map(), schema()) :: {:ok, map()} | {:error, [ValidationError.t()]}
  def normalize_inputs(inputs, schema) when is_map(inputs) and is_list(schema) do
    normalized_inputs = stringify_keys(inputs)

    {resolved_inputs, errors} =
      Enum.reduce(schema, {normalized_inputs, []}, fn input, {acc_inputs, acc_errors} ->
        apply_input_rule(input, acc_inputs, acc_errors)
      end)

    case Enum.reverse(errors) do
      [] -> {:ok, resolved_inputs}
      validation_errors -> {:error, validation_errors}
    end
  end

  def normalize_inputs(inputs, _schema) do
    {:error,
     [
       %ValidationError{
         path: ["inputs"],
         code: :invalid_type,
         message: "workflow inputs must be a map, got: #{inspect(inputs)}"
       }
     ]}
  end

  defp apply_input_rule(input, inputs, errors) do
    name = fetch(input, "name")
    type = fetch(input, "type")
    required = fetch(input, "required") == true
    default = fetch(input, "default")

    cond do
      not is_binary(name) or name == "" ->
        {inputs,
         [error(["inputs"], :invalid_value, "input declaration is missing a name") | errors]}

      Map.has_key?(inputs, name) ->
        value = Map.get(inputs, name)

        if matches_type?(value, type) do
          {inputs, errors}
        else
          {inputs, [type_error(name, type, value) | errors]}
        end

      default == nil ->
        if required do
          {inputs,
           [error(["inputs", name], :required, "required input is missing: #{name}") | errors]}
        else
          {inputs, errors}
        end

      true ->
        if matches_type?(default, type) do
          {Map.put(inputs, name, default), errors}
        else
          {inputs, [type_error(name, type, default) | errors]}
        end
    end
  end

  defp serialize_input(%DefinitionInput{} = input) do
    %{
      name: input.name,
      type: input.type,
      required: input.required || false,
      default: input.default,
      description: input.description
    }
  end

  defp matches_type?(value, "string"), do: is_binary(value)
  defp matches_type?(value, "integer"), do: is_integer(value)
  defp matches_type?(value, "boolean"), do: is_boolean(value)
  defp matches_type?(value, "map"), do: is_map(value)
  defp matches_type?(value, "list"), do: is_list(value)
  defp matches_type?(_value, _type), do: false

  defp type_error(name, expected, value) do
    error(
      ["inputs", name],
      :invalid_type,
      "input #{name} must be #{expected}, got #{type_name(value)}"
    )
  end

  defp type_name(value) when is_binary(value), do: "string"
  defp type_name(value) when is_integer(value), do: "integer"
  defp type_name(value) when is_boolean(value), do: "boolean"
  defp type_name(value) when is_map(value), do: "map"
  defp type_name(value) when is_list(value), do: "list"
  defp type_name(value), do: value |> Kernel.inspect()

  defp error(path, code, message), do: %ValidationError{path: path, code: code, message: message}

  defp fetch(map, key) when is_map(map) and is_binary(key) do
    Map.get(map, key) || fetch_atom_key(map, key)
  end

  defp fetch(_map, _key), do: nil

  defp fetch_atom_key(map, key) do
    Enum.find_value(map, fn
      {atom_key, value} when is_atom(atom_key) ->
        if Atom.to_string(atom_key) == key, do: value

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
end
