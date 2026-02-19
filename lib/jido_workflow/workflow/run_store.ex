defmodule JidoWorkflow.Workflow.RunStore do
  @moduledoc """
  In-memory store for workflow run lifecycle state.
  """

  use GenServer

  @type status :: :running | :completed | :failed

  @type run :: %{
          run_id: String.t(),
          workflow_id: String.t(),
          status: status(),
          backend: :direct | :strategy | nil,
          inputs: map(),
          started_at: DateTime.t(),
          finished_at: DateTime.t() | nil,
          result: term(),
          error: term()
        }

  @type start_attrs :: %{
          required(:run_id) => String.t(),
          required(:workflow_id) => String.t(),
          optional(:backend) => :direct | :strategy,
          optional(:inputs) => map(),
          optional(:started_at) => DateTime.t()
        }

  @type finish_attrs :: %{
          optional(:workflow_id) => String.t(),
          optional(:backend) => :direct | :strategy,
          optional(:inputs) => map(),
          optional(:finished_at) => DateTime.t()
        }

  @default_max_runs 1_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec record_started(start_attrs(), GenServer.server()) :: :ok | {:error, term()}
  def record_started(attrs, server \\ __MODULE__) when is_map(attrs) do
    GenServer.call(server, {:record_started, attrs})
  end

  @spec record_completed(String.t(), term(), finish_attrs(), GenServer.server()) ::
          :ok | {:error, term()}
  def record_completed(run_id, result, attrs \\ %{}, server \\ __MODULE__)
      when is_binary(run_id) and is_map(attrs) do
    GenServer.call(server, {:record_completed, run_id, result, attrs})
  end

  @spec record_failed(String.t(), term(), finish_attrs(), GenServer.server()) ::
          :ok | {:error, term()}
  def record_failed(run_id, error, attrs \\ %{}, server \\ __MODULE__)
      when is_binary(run_id) and is_map(attrs) do
    GenServer.call(server, {:record_failed, run_id, error, attrs})
  end

  @spec get(String.t(), GenServer.server()) :: {:ok, run()} | {:error, :not_found}
  def get(run_id, server \\ __MODULE__) when is_binary(run_id) do
    GenServer.call(server, {:get, run_id})
  end

  @spec list(GenServer.server(), keyword()) :: [run()]
  def list(server \\ __MODULE__, opts \\ []) when is_list(opts) do
    GenServer.call(server, {:list, opts})
  end

  @impl true
  def init(opts) do
    max_runs =
      case Keyword.get(opts, :max_runs, @default_max_runs) do
        value when is_integer(value) and value > 0 -> value
        _ -> @default_max_runs
      end

    {:ok, %{runs: %{}, order: [], max_runs: max_runs}}
  end

  @impl true
  def handle_call({:record_started, attrs}, _from, state) do
    case normalize_started(attrs) do
      {:ok, run} ->
        {:reply, :ok, put_run(state, run)}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:record_completed, run_id, result, attrs}, _from, state) do
    run =
      state.runs
      |> Map.get(run_id)
      |> build_or_merge_base_run(run_id, attrs)
      |> Map.merge(%{
        status: :completed,
        finished_at: fetch_datetime(attrs, :finished_at, DateTime.utc_now()),
        result: result,
        error: nil
      })

    {:reply, :ok, put_run(state, run)}
  end

  def handle_call({:record_failed, run_id, error, attrs}, _from, state) do
    run =
      state.runs
      |> Map.get(run_id)
      |> build_or_merge_base_run(run_id, attrs)
      |> Map.merge(%{
        status: :failed,
        finished_at: fetch_datetime(attrs, :finished_at, DateTime.utc_now()),
        error: error
      })

    {:reply, :ok, put_run(state, run)}
  end

  def handle_call({:get, run_id}, _from, state) do
    reply =
      case Map.get(state.runs, run_id) do
        nil -> {:error, :not_found}
        run -> {:ok, run}
      end

    {:reply, reply, state}
  end

  def handle_call({:list, opts}, _from, state) do
    workflow_id = Keyword.get(opts, :workflow_id)
    status = Keyword.get(opts, :status)

    limit =
      case Keyword.get(opts, :limit) do
        value when is_integer(value) and value > 0 -> value
        _ -> nil
      end

    runs =
      state.order
      |> Enum.map(&Map.get(state.runs, &1))
      |> Enum.reject(&is_nil/1)
      |> maybe_filter_workflow(workflow_id)
      |> maybe_filter_status(status)
      |> maybe_limit(limit)

    {:reply, runs, state}
  end

  defp normalize_started(attrs) when is_map(attrs) do
    with {:ok, run_id} <- required_binary(attrs, :run_id),
         {:ok, workflow_id} <- required_binary(attrs, :workflow_id) do
      {:ok,
       %{
         run_id: run_id,
         workflow_id: workflow_id,
         status: :running,
         backend: fetch_backend(attrs),
         inputs: fetch_map(attrs, :inputs),
         started_at: fetch_datetime(attrs, :started_at, DateTime.utc_now()),
         finished_at: nil,
         result: nil,
         error: nil
       }}
    end
  end

  defp normalize_started(_attrs), do: {:error, :invalid_started_attrs}

  defp required_binary(attrs, key) do
    case fetch(attrs, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:missing_or_invalid, key}}
    end
  end

  defp build_or_merge_base_run(nil, run_id, attrs) do
    %{
      run_id: run_id,
      workflow_id: fetch(attrs, :workflow_id) || "workflow",
      status: :running,
      backend: fetch_backend(attrs),
      inputs: fetch_map(attrs, :inputs),
      started_at: DateTime.utc_now(),
      finished_at: nil,
      result: nil,
      error: nil
    }
  end

  defp build_or_merge_base_run(run, _run_id, attrs) do
    run
    |> maybe_put(:workflow_id, fetch(attrs, :workflow_id))
    |> maybe_put(:backend, fetch_backend(attrs))
    |> maybe_put_map(:inputs, fetch(attrs, :inputs))
  end

  defp maybe_put(run, _key, nil), do: run
  defp maybe_put(run, key, value), do: Map.put(run, key, value)

  defp maybe_put_map(run, _key, value) when not is_map(value), do: run
  defp maybe_put_map(run, key, value), do: Map.put(run, key, value)

  defp fetch_backend(attrs) do
    case fetch(attrs, :backend) do
      backend when backend in [:direct, :strategy] -> backend
      _ -> nil
    end
  end

  defp fetch_map(attrs, key) do
    case fetch(attrs, key) do
      value when is_map(value) -> value
      _ -> %{}
    end
  end

  defp fetch_datetime(attrs, key, fallback) do
    case fetch(attrs, key) do
      %DateTime{} = value -> value
      _ -> fallback
    end
  end

  defp fetch(attrs, key) when is_map(attrs) and is_atom(key) do
    Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))
  end

  defp put_run(state, run) do
    run_id = run.run_id
    order = [run_id | Enum.reject(state.order, &(&1 == run_id))]
    runs = Map.put(state.runs, run_id, run)
    prune_runs(%{state | runs: runs, order: order})
  end

  defp prune_runs(state) do
    if length(state.order) > state.max_runs do
      {keep, drop} = Enum.split(state.order, state.max_runs)
      runs = Enum.reduce(drop, state.runs, &Map.delete(&2, &1))
      %{state | runs: runs, order: keep}
    else
      state
    end
  end

  defp maybe_filter_workflow(runs, nil), do: runs

  defp maybe_filter_workflow(runs, workflow_id) when is_binary(workflow_id) do
    Enum.filter(runs, &(&1.workflow_id == workflow_id))
  end

  defp maybe_filter_workflow(runs, _workflow_id), do: runs

  defp maybe_filter_status(runs, nil), do: runs

  defp maybe_filter_status(runs, status) when status in [:running, :completed, :failed] do
    Enum.filter(runs, &(&1.status == status))
  end

  defp maybe_filter_status(runs, _status), do: runs

  defp maybe_limit(runs, nil), do: runs
  defp maybe_limit(runs, limit), do: Enum.take(runs, limit)
end
