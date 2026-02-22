defmodule Jido.Code.Workflow.HookRuntime do
  @moduledoc """
  Subscribes to workflow lifecycle signals and emits hook callbacks.
  """

  use GenServer

  alias Jido.Code.Workflow.Broadcaster
  alias Jido.Code.Workflow.Hooks.NoopAdapter
  alias Jido.Code.Workflow.HooksIntegration
  alias Jido.Signal
  alias Jido.Signal.Bus

  @type state :: %{
          bus: atom(),
          adapter: module(),
          subscription_ids: [String.t()]
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec status(GenServer.server()) :: map()
  def status(server \\ __MODULE__) do
    GenServer.call(server, :status)
  end

  @impl true
  def init(opts) do
    bus = Keyword.get(opts, :bus, Broadcaster.default_bus())
    adapter = normalize_adapter(Keyword.get(opts, :adapter, default_adapter()))

    case subscribe_all(bus) do
      {:ok, subscription_ids} ->
        {:ok, %{bus: bus, adapter: adapter, subscription_ids: subscription_ids}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def terminate(_reason, state) do
    unsubscribe_all(state.bus, state.subscription_ids)
    :ok
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply,
     %{
       bus: state.bus,
       adapter: state.adapter,
       subscription_count: length(state.subscription_ids)
     }, state}
  end

  @impl true
  def handle_info({:signal, %Signal{} = signal}, state) do
    _ = HooksIntegration.emit_signal_hook(signal, adapter: state.adapter)
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp subscribe_all(bus) do
    HooksIntegration.supported_signal_types()
    |> Enum.reduce_while({:ok, []}, fn signal_type, {:ok, subscription_ids} ->
      case Bus.subscribe(bus, signal_type, dispatch: {:pid, target: self()}) do
        {:ok, subscription_id} ->
          {:cont, {:ok, [subscription_id | subscription_ids]}}

        {:error, reason} ->
          unsubscribe_all(bus, subscription_ids)
          {:halt, {:error, {:subscribe_failed, signal_type, reason}}}
      end
    end)
    |> then(fn
      {:ok, subscription_ids} -> {:ok, Enum.reverse(subscription_ids)}
      {:error, reason} -> {:error, reason}
    end)
  end

  defp unsubscribe_all(_bus, []), do: :ok

  defp unsubscribe_all(bus, subscription_ids) do
    Enum.each(subscription_ids, fn subscription_id ->
      _ = Bus.unsubscribe(bus, subscription_id)
    end)
  end

  defp normalize_adapter(module) when is_atom(module), do: module
  defp normalize_adapter(_module), do: NoopAdapter

  defp default_adapter do
    Application.get_env(:jido_workflow, :workflow_hook_adapter, NoopAdapter)
  end
end
