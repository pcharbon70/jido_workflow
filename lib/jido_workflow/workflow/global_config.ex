defmodule JidoWorkflow.Workflow.GlobalConfig do
  @moduledoc """
  Loads optional runtime configuration from `.jido_code/config.json`.

  The file allows local-project overrides for runtime wiring defaults that are
  otherwise provided by application environment.
  """

  alias JidoWorkflow.Workflow.ValidationError

  @type backend :: :direct | :strategy

  @type runtime_overrides :: %{
          optional(:workflow_dir) => String.t(),
          optional(:triggers_config_path) => String.t(),
          optional(:trigger_sync_interval_ms) => pos_integer(),
          optional(:trigger_backend) => backend()
        }

  @type result :: {:ok, runtime_overrides()} | {:error, [ValidationError.t()]}

  @spec load_file(Path.t() | nil) :: result()
  def load_file(nil), do: {:ok, %{}}

  def load_file(path) when is_binary(path) do
    expanded_path = Path.expand(path)

    if File.exists?(expanded_path) do
      with {:ok, contents} <- File.read(expanded_path),
           {:ok, decoded} <- Jason.decode(contents),
           {:ok, map} <- ensure_map(decoded) do
        normalize(map, Path.dirname(expanded_path))
      else
        {:error, errors} when is_list(errors) ->
          {:error, errors}

        {:error, reason} ->
          {:error, [error(["config_file"], :invalid_config, format_reason(reason))]}
      end
    else
      {:ok, %{}}
    end
  end

  def load_file(other) do
    {:error,
     [
       error(
         ["config_file"],
         :invalid_type,
         "config path must be a string, got: #{inspect(other)}"
       )
     ]}
  end

  defp ensure_map(value) when is_map(value), do: {:ok, value}

  defp ensure_map(_other),
    do: {:error, [error(["config_file"], :invalid_type, "config must be a JSON object")]}

  defp normalize(config, base_dir) do
    workflow_dir_ref = locate(config, "workflow_dir")
    triggers_path_ref = locate(config, "triggers_config_path")
    sync_interval_ref = locate(config, "trigger_sync_interval_ms")
    backend_ref = locate(config, "trigger_backend", fallback: ["backend", "workflow_backend"])

    {workflow_dir, errors} = normalize_optional_path(workflow_dir_ref, base_dir, [])
    {triggers_config_path, errors} = normalize_optional_path(triggers_path_ref, base_dir, errors)
    {trigger_sync_interval_ms, errors} = normalize_positive_integer(sync_interval_ref, errors)
    {trigger_backend, errors} = normalize_backend(backend_ref, errors)

    if errors == [] do
      {:ok,
       %{}
       |> maybe_put(:workflow_dir, workflow_dir)
       |> maybe_put(:triggers_config_path, triggers_config_path)
       |> maybe_put(:trigger_sync_interval_ms, trigger_sync_interval_ms)
       |> maybe_put(:trigger_backend, trigger_backend)}
    else
      {:error, Enum.reverse(errors)}
    end
  end

  defp locate(config, key, opts \\ []) when is_map(config) and is_binary(key) do
    fallback = Keyword.get(opts, :fallback, [])

    case lookup_in_map(config, key) do
      {:ok, value} ->
        %{value: value, path: [key]}

      :error ->
        case lookup_in_nested_workflow(config, key) do
          {:ok, value} ->
            %{value: value, path: ["workflow", key]}

          :error ->
            locate_fallback(config, fallback)
        end
    end
  end

  defp locate_fallback(_config, []), do: %{value: nil, path: []}

  defp locate_fallback(config, [key | rest]) do
    case locate(config, key) do
      %{value: nil} -> locate_fallback(config, rest)
      located -> located
    end
  end

  defp lookup_in_map(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        {:ok, value}

      :error ->
        lookup_atom_key(map, key)
    end
  end

  defp lookup_in_nested_workflow(config, key) do
    case lookup_in_map(config, "workflow") do
      {:ok, workflow} when is_map(workflow) -> lookup_in_map(workflow, key)
      _other -> :error
    end
  end

  defp lookup_atom_key(map, key) do
    Enum.find_value(map, :error, fn
      {map_key, map_value} when is_atom(map_key) ->
        if Atom.to_string(map_key) == key, do: {:ok, map_value}

      _other ->
        nil
    end)
  end

  defp normalize_optional_path(%{value: nil}, _base_dir, errors), do: {nil, errors}

  defp normalize_optional_path(%{value: value, path: path}, base_dir, errors)
       when is_binary(value) do
    trimmed = String.trim(value)

    if trimmed == "" do
      {nil, [error(path, :invalid_value, "must be a non-empty string") | errors]}
    else
      {Path.expand(trimmed, base_dir), errors}
    end
  end

  defp normalize_optional_path(%{path: path}, _base_dir, errors) do
    {nil, [error(path, :invalid_type, "must be a string") | errors]}
  end

  defp normalize_positive_integer(%{value: nil}, errors), do: {nil, errors}

  defp normalize_positive_integer(%{value: value}, errors)
       when is_integer(value) and value > 0 do
    {value, errors}
  end

  defp normalize_positive_integer(%{path: path}, errors) do
    {nil, [error(path, :invalid_value, "must be a positive integer") | errors]}
  end

  defp normalize_backend(%{value: nil}, errors), do: {nil, errors}
  defp normalize_backend(%{value: :direct}, errors), do: {:direct, errors}
  defp normalize_backend(%{value: :strategy}, errors), do: {:strategy, errors}

  defp normalize_backend(%{value: value, path: path}, errors) when is_binary(value) do
    case String.downcase(String.trim(value)) do
      "direct" ->
        {:direct, errors}

      "strategy" ->
        {:strategy, errors}

      _other ->
        {nil, [error(path, :invalid_value, "must be \"direct\" or \"strategy\"") | errors]}
    end
  end

  defp normalize_backend(%{path: path}, errors) do
    {nil, [error(path, :invalid_type, "must be \"direct\" or \"strategy\"") | errors]}
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp format_reason(%Jason.DecodeError{} = error), do: Exception.message(error)
  defp format_reason(reason), do: inspect(reason)

  defp error(path, code, message), do: %ValidationError{path: path, code: code, message: message}
end
