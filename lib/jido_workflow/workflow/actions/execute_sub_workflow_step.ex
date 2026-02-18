defmodule JidoWorkflow.Workflow.Actions.ExecuteSubWorkflowStep do
  @moduledoc """
  Executes compiled sub-workflow steps.

  Sub-workflow step metadata includes:
  - target workflow id
  - input bindings resolved from workflow state
  - optional condition binding
  """

  alias JidoWorkflow.Workflow.ArgumentResolver
  alias JidoWorkflow.Workflow.Engine
  alias JidoWorkflow.Workflow.Registry

  use Jido.Action,
    name: "workflow_execute_sub_workflow_step",
    description: "Execute a compiled workflow sub-workflow step",
    schema: [
      step: [type: :map, required: true]
    ]

  @impl true
  def run(%{step: step} = params, _context) do
    state =
      params
      |> extract_runtime_state()
      |> ArgumentResolver.normalize_state()

    with {:ok, step_meta} <- normalize_step(step),
         {:ok, should_run?} <- evaluate_condition(step_meta.condition, state),
         {:ok, step_result} <- execute_sub_workflow(step_meta, state, should_run?, params) do
      {:ok, ArgumentResolver.put_result(state, step_meta.name, step_result)}
    end
  end

  defp extract_runtime_state(params) when is_map(params) do
    case fetch(params, "input") do
      nil ->
        params
        |> Map.delete(:step)
        |> Map.delete("step")

      input ->
        input
    end
  end

  defp normalize_step(step) when is_map(step) do
    name = fetch(step, "name")
    workflow = fetch(step, "workflow")
    inputs = fetch(step, "inputs") || %{}
    condition = fetch(step, "condition")

    cond do
      is_nil(name) ->
        {:error, {:invalid_step, "step name is missing"}}

      is_nil(workflow) ->
        {:error, {:invalid_step, "sub_workflow target is missing"}}

      true ->
        {:ok,
         %{
           name: to_string(name),
           workflow: to_string(workflow),
           inputs: inputs,
           condition: condition
         }}
    end
  end

  defp normalize_step(other),
    do: {:error, {:invalid_step, "step must be a map, got: #{inspect(other)}"}}

  defp evaluate_condition(nil, _state), do: {:ok, true}

  defp evaluate_condition(condition, state) do
    with {:ok, resolved} <- ArgumentResolver.resolve_inputs(%{"condition" => condition}, state) do
      {:ok, truthy?(resolved["condition"])}
    end
  end

  defp execute_sub_workflow(_step_meta, _state, false, _params) do
    {:ok, %{"status" => "skipped", "reason" => "condition_not_met"}}
  end

  defp execute_sub_workflow(step_meta, state, true, params) do
    with {:ok, resolved_inputs} <- ArgumentResolver.resolve_inputs(step_meta.inputs, state) do
      registry = fetch(params, "registry") || default_registry()
      backend = normalize_backend(fetch(params, "backend"))

      case Engine.execute(step_meta.workflow, resolved_inputs,
             registry: registry,
             backend: backend
           ) do
        {:ok, execution} ->
          {:ok, execution.result}

        {:error, :not_found} ->
          {:error, {:sub_workflow_not_found, step_meta.workflow}}

        {:error, reason} ->
          {:error, {:sub_workflow_failed, step_meta.workflow, reason}}
      end
    end
  end

  defp default_registry do
    Application.get_env(:jido_workflow, :workflow_registry, Registry)
  end

  defp normalize_backend(value) when value in [:direct, :strategy], do: value

  defp normalize_backend(value) when is_binary(value) do
    case String.downcase(value) do
      "strategy" -> :strategy
      _ -> :direct
    end
  end

  defp normalize_backend(_value), do: :direct

  defp truthy?(false), do: false
  defp truthy?(nil), do: false
  defp truthy?(_), do: true

  defp fetch(step, key) when is_map(step) do
    case Map.fetch(step, key) do
      {:ok, value} -> value
      :error -> fetch_atom_key(step, key)
    end
  end

  defp fetch_atom_key(step, key) do
    Enum.find_value(step, fn
      {map_key, map_value} when is_atom(map_key) ->
        if Atom.to_string(map_key) == key, do: map_value

      _other ->
        nil
    end)
  end
end
