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
          subscriptions_by_signal_type: %{String.t() => String.t()}
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
      {:ok, subscriptions_by_signal_type} ->
        {:ok,
         %{
           bus: bus,
           adapter: adapter,
           subscriptions_by_signal_type: subscriptions_by_signal_type
         }}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def terminate(_reason, state) do
    unsubscribe_all(state.bus, Map.values(state.subscriptions_by_signal_type))
    :ok
  end

  @impl true
  def handle_call(:status, _from, state) do
    supported_signal_types = HooksIntegration.supported_signal_types()

    subscribed_signal_types =
      state.subscriptions_by_signal_type
      |> Map.keys()
      |> Enum.sort()

    {:reply,
     %{
       bus: state.bus,
       adapter: state.adapter,
       subscription_count: map_size(state.subscriptions_by_signal_type),
       supported_signal_types: supported_signal_types,
       subscribed_signal_types: subscribed_signal_types,
       missing_signal_types: supported_signal_types -- subscribed_signal_types
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
    |> Enum.reduce_while({:ok, %{}}, fn signal_type, {:ok, subscriptions_by_signal_type} ->
      case Bus.subscribe(bus, signal_type, dispatch: {:pid, target: self()}) do
        {:ok, subscription_id} ->
          {:cont,
           {:ok, Map.put(subscriptions_by_signal_type, signal_type, subscription_id)}}

        {:error, reason} ->
          unsubscribe_all(bus, Map.values(subscriptions_by_signal_type))
          {:halt, {:error, {:subscribe_failed, signal_type, reason}}}
      end
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
