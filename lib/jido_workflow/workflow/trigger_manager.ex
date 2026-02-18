defmodule JidoWorkflow.Workflow.TriggerManager do
  @moduledoc """
  Syncs trigger processes from workflow definitions in the workflow registry.
  """

  alias JidoWorkflow.Workflow.Broadcaster
  alias JidoWorkflow.Workflow.Registry, as: WorkflowRegistry
  alias JidoWorkflow.Workflow.TriggerSupervisor

  @default_process_registry JidoWorkflow.Workflow.TriggerProcessRegistry

  @type sync_summary :: %{
          desired: non_neg_integer(),
          started: non_neg_integer(),
          skipped: non_neg_integer(),
          stopped: non_neg_integer(),
          unsupported: non_neg_integer(),
          errors: [term()]
        }

  @spec sync_from_registry(keyword()) :: {:ok, sync_summary()} | {:error, term()}
  def sync_from_registry(opts \\ []) do
    workflow_registry = Keyword.get(opts, :workflow_registry, default_workflow_registry())
    trigger_supervisor = Keyword.get(opts, :trigger_supervisor, TriggerSupervisor)
    process_registry = process_registry(opts)

    with {:ok, desired_configs} <- desired_trigger_configs(workflow_registry, opts) do
      desired_ids = MapSet.new(desired_configs, & &1.id)

      existing_ids =
        MapSet.new(TriggerSupervisor.list_trigger_ids(process_registry: process_registry))

      stopped =
        existing_ids
        |> MapSet.difference(desired_ids)
        |> MapSet.to_list()
        |> stop_triggers(trigger_supervisor, process_registry)

      start_stats =
        Enum.reduce(
          desired_configs,
          %{started: 0, skipped: 0, unsupported: 0, errors: []},
          fn config, acc ->
            maybe_start_trigger(
              config,
              existing_ids,
              trigger_supervisor,
              process_registry,
              acc
            )
          end
        )

      {:ok,
       %{
         desired: length(desired_configs),
         started: start_stats.started,
         skipped: start_stats.skipped,
         stopped: stopped,
         unsupported: start_stats.unsupported,
         errors: Enum.reverse(start_stats.errors)
       }}
    end
  end

  defp maybe_start_trigger(config, existing_ids, trigger_supervisor, process_registry, acc) do
    if MapSet.member?(existing_ids, config.id) do
      %{acc | skipped: acc.skipped + 1}
    else
      config
      |> TriggerSupervisor.start_trigger(
        supervisor: trigger_supervisor,
        process_registry: process_registry
      )
      |> apply_start_result(acc)
    end
  end

  defp apply_start_result({:ok, _pid}, acc), do: %{acc | started: acc.started + 1}

  defp apply_start_result({:error, {:unsupported_trigger_type, _type} = reason}, acc) do
    %{acc | unsupported: acc.unsupported + 1, errors: [reason | acc.errors]}
  end

  defp apply_start_result({:error, reason}, acc) do
    %{acc | errors: [reason | acc.errors]}
  end

  defp desired_trigger_configs(workflow_registry, opts) do
    bus = Keyword.get(opts, :bus, Broadcaster.default_bus())
    backend = Keyword.get(opts, :backend)
    process_registry = process_registry(opts)

    try do
      workflows =
        WorkflowRegistry.list(workflow_registry, include_disabled: false, include_invalid: false)

      {configs, errors} =
        Enum.reduce(workflows, {[], []}, fn workflow, {acc, err_acc} ->
          workflow_id = workflow.id

          case WorkflowRegistry.get_definition(workflow_id, workflow_registry) do
            {:ok, definition} ->
              trigger_configs =
                definition.triggers
                |> List.wrap()
                |> Enum.with_index()
                |> Enum.map(fn {trigger, index} ->
                  build_trigger_config(
                    workflow_id,
                    trigger,
                    index,
                    workflow_registry,
                    bus,
                    backend,
                    process_registry
                  )
                end)

              {acc ++ trigger_configs, err_acc}

            {:error, reason} ->
              {acc, [{workflow_id, reason} | err_acc]}
          end
        end)

      if errors == [] do
        {:ok, configs}
      else
        {:error, Enum.reverse(errors)}
      end
    rescue
      error ->
        {:error, {:registry_access_failed, Exception.message(error)}}
    end
  end

  defp stop_triggers(trigger_ids, trigger_supervisor, process_registry) do
    Enum.reduce(trigger_ids, 0, fn trigger_id, stopped ->
      case TriggerSupervisor.stop_trigger(trigger_id,
             supervisor: trigger_supervisor,
             process_registry: process_registry
           ) do
        :ok -> stopped + 1
        {:error, :not_found} -> stopped
      end
    end)
  end

  defp build_trigger_config(
         workflow_id,
         trigger,
         index,
         workflow_registry,
         bus,
         backend,
         process_registry
       ) do
    %{
      id: "#{workflow_id}:#{trigger.type}:#{index}",
      workflow_id: workflow_id,
      type: trigger.type,
      patterns: trigger.patterns,
      events: trigger.events,
      schedule: trigger.schedule,
      command: trigger.command,
      debounce_ms: trigger.debounce_ms,
      workflow_registry: workflow_registry,
      bus: bus,
      backend: backend,
      process_registry: process_registry
    }
  end

  defp default_workflow_registry do
    Application.get_env(:jido_workflow, :workflow_registry, WorkflowRegistry)
  end

  defp process_registry(opts) do
    Keyword.get_lazy(opts, :process_registry, fn ->
      Application.get_env(:jido_workflow, :trigger_process_registry, @default_process_registry)
    end)
  end
end
