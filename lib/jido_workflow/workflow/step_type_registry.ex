defmodule JidoWorkflow.Workflow.StepTypeRegistry do
  @moduledoc """
  Registry for workflow step types.

  Built-in step types are always available:
  - `action`
  - `agent`
  - `skill`
  - `sub_workflow`

  Plugins can register additional step types at runtime.
  """

  @env_key :workflow_step_types

  @builtin_types %{
    "action" => {:builtin, :action},
    "agent" => {:builtin, :agent},
    "skill" => {:builtin, :skill},
    "sub_workflow" => {:builtin, :sub_workflow}
  }

  @type builtin_type :: {:builtin, :action | :agent | :skill | :sub_workflow}
  @type entry :: builtin_type() | module()

  @spec all() :: %{String.t() => entry()}
  def all do
    Map.merge(@builtin_types, custom_types())
  end

  @spec supported_types() :: [String.t()]
  def supported_types do
    all()
    |> Map.keys()
    |> Enum.sort()
  end

  @spec resolve(String.t() | atom() | term()) ::
          {:ok, entry()} | {:error, {:unsupported_step_type, String.t() | nil}}
  def resolve(type) do
    case normalize_type(type) do
      nil ->
        {:error, {:unsupported_step_type, nil}}

      normalized ->
        case Map.fetch(all(), normalized) do
          {:ok, entry} -> {:ok, entry}
          :error -> {:error, {:unsupported_step_type, normalized}}
        end
    end
  end

  @spec register(String.t() | atom(), module()) :: :ok | {:error, term()}
  def register(type, module) when is_atom(module) do
    with {:ok, normalized} <- normalize_registration_type(type),
         :ok <- ensure_not_builtin(normalized) do
      Application.put_env(
        :jido_workflow,
        @env_key,
        Map.put(custom_types(), normalized, module)
      )

      :ok
    end
  end

  def register(_type, _module), do: {:error, :invalid_module}

  @spec unregister(String.t() | atom()) :: :ok
  def unregister(type) do
    case normalize_type(type) do
      nil ->
        :ok

      normalized ->
        Application.put_env(
          :jido_workflow,
          @env_key,
          Map.delete(custom_types(), normalized)
        )

        :ok
    end
  end

  @spec custom_types() :: %{String.t() => module()}
  def custom_types do
    case Application.get_env(:jido_workflow, @env_key, %{}) do
      map when is_map(map) ->
        normalize_custom_types(map)

      _other ->
        %{}
    end
  end

  defp normalize_registration_type(type) do
    case normalize_type(type) do
      nil -> {:error, :invalid_type}
      normalized -> {:ok, normalized}
    end
  end

  defp ensure_not_builtin(type) do
    if Map.has_key?(@builtin_types, type) do
      {:error, {:reserved_step_type, type}}
    else
      :ok
    end
  end

  defp normalize_custom_types(map) do
    Enum.reduce(map, %{}, fn entry, acc ->
      case normalize_custom_entry(entry) do
        {:ok, {type, module}} -> Map.put(acc, type, module)
        :error -> acc
      end
    end)
  end

  defp normalize_custom_entry({type, module}) do
    case {normalize_type(type), module} do
      {normalized, value} when is_binary(normalized) and is_atom(value) ->
        {:ok, {normalized, value}}

      _other ->
        :error
    end
  end

  defp normalize_type(type) when is_atom(type), do: normalize_type(Atom.to_string(type))

  defp normalize_type(type) when is_binary(type) do
    normalized = String.trim(type)
    if normalized == "", do: nil, else: normalized
  end

  defp normalize_type(_type), do: nil
end
