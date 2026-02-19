defmodule JidoWorkflow.Workflow.TriggerTypeRegistry do
  @moduledoc """
  Registry for workflow trigger types.

  Built-in trigger types are always available:
  - `file_system`
  - `git_hook`
  - `scheduled`
  - `signal`
  - `manual`

  Plugins can register additional trigger types at runtime.
  """

  alias JidoWorkflow.Workflow.Triggers.FileSystem
  alias JidoWorkflow.Workflow.Triggers.GitHook
  alias JidoWorkflow.Workflow.Triggers.Manual
  alias JidoWorkflow.Workflow.Triggers.Scheduled
  alias JidoWorkflow.Workflow.Triggers.Signal

  @env_key :workflow_trigger_types

  @builtin_types %{
    "file_system" => FileSystem,
    "git_hook" => GitHook,
    "scheduled" => Scheduled,
    "signal" => Signal,
    "manual" => Manual
  }

  @spec all() :: %{String.t() => module()}
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
          {:ok, module()} | {:error, {:unsupported_trigger_type, String.t() | nil}}
  def resolve(type) do
    case normalize_type(type) do
      nil ->
        {:error, {:unsupported_trigger_type, nil}}

      normalized ->
        case Map.fetch(all(), normalized) do
          {:ok, module} -> {:ok, module}
          :error -> {:error, {:unsupported_trigger_type, normalized}}
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
      {:error, {:reserved_trigger_type, type}}
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
