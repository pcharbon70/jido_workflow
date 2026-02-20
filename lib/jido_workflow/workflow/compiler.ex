defmodule JidoWorkflow.Workflow.Compiler do
  @moduledoc """
  Compiles validated workflow definitions into executable Runic workflow bundles.
  """

  alias Jido.Runic.ActionNode
  alias JidoWorkflow.Workflow.Actions.ExecuteActionStep
  alias JidoWorkflow.Workflow.Actions.ExecuteAgentStep
  alias JidoWorkflow.Workflow.Actions.ExecuteSkillStep
  alias JidoWorkflow.Workflow.Actions.ExecuteSubWorkflowStep
  alias JidoWorkflow.Workflow.Definition
  alias JidoWorkflow.Workflow.Definition.RetryPolicy, as: DefinitionRetryPolicy
  alias JidoWorkflow.Workflow.Definition.Settings, as: DefinitionSettings
  alias JidoWorkflow.Workflow.Definition.Signals, as: DefinitionSignals
  alias JidoWorkflow.Workflow.Definition.Step, as: DefinitionStep
  alias JidoWorkflow.Workflow.InputContract
  alias JidoWorkflow.Workflow.StepTypeRegistry
  alias JidoWorkflow.Workflow.ValidationError
  alias Runic.Workflow

  @type compiled_bundle :: %{
          workflow: Workflow.t(),
          input_schema: [
            %{
              name: String.t(),
              type: String.t(),
              required: boolean(),
              default: term(),
              description: String.t() | nil
            }
          ],
          return: %{value: String.t() | nil, transform: String.t() | nil},
          signals: %{topic: String.t() | nil, publish_events: [String.t()] | nil} | nil,
          error_handling: [map()],
          settings:
            %{
              max_concurrency: pos_integer() | nil,
              timeout_ms: pos_integer() | nil,
              retry_policy:
                %{
                  max_retries: non_neg_integer() | nil,
                  backoff: String.t() | nil,
                  base_delay_ms: non_neg_integer() | nil
                }
                | nil,
              on_failure: String.t() | nil
            }
            | nil,
          metadata: %{
            name: String.t(),
            version: String.t(),
            description: String.t() | nil,
            enabled: boolean()
          }
        }

  @spec compile(Definition.t()) :: {:ok, compiled_bundle()} | {:error, [ValidationError.t()]}
  def compile(%Definition{} = definition) do
    steps = definition.steps || []
    compiled_signals = compile_signals(definition.signals)

    with :ok <- ensure_unique_step_names(steps),
         :ok <- ensure_dependencies_exist(steps),
         {:ok, ordered_steps} <- topological_sort(steps),
         {:ok, workflow} <- build_workflow(definition.name, ordered_steps) do
      {:ok,
       %{
         workflow: workflow,
         input_schema: InputContract.compile_schema(definition.inputs),
         return: compile_return(definition.return),
         signals: compiled_signals,
         error_handling: compile_error_handling(definition.error_handling),
         settings: compile_settings(definition.settings),
         metadata: %{
           name: definition.name,
           version: definition.version,
           description: definition.description,
           enabled: definition.enabled
         }
       }}
    end
  end

  def compile(other) do
    {:error, [error([], :invalid_type, "definition must be a struct, got: #{inspect(other)}")]}
  end

  defp ensure_unique_step_names(steps) do
    errors =
      steps
      |> Enum.with_index()
      |> Enum.reduce(%{}, fn {%DefinitionStep{name: name}, index}, acc ->
        Map.update(acc, name, [index], &[index | &1])
      end)
      |> Enum.filter(fn {_name, indexes} -> length(indexes) > 1 end)
      |> Enum.flat_map(fn {name, indexes} ->
        indexes
        |> Enum.sort()
        |> Enum.map(fn index ->
          error(
            ["steps", Integer.to_string(index), "name"],
            :duplicate,
            "duplicate step name: #{name}"
          )
        end)
      end)

    if errors == [], do: :ok, else: {:error, errors}
  end

  defp ensure_dependencies_exist(steps) do
    names = MapSet.new(steps, & &1.name)

    errors =
      steps
      |> Enum.with_index()
      |> Enum.flat_map(fn {%DefinitionStep{name: name, depends_on: depends_on}, index} ->
        dependencies = Enum.uniq(depends_on || [])
        path = ["steps", Integer.to_string(index), "depends_on"]

        missing_errors =
          dependencies
          |> Enum.reject(&MapSet.member?(names, &1))
          |> Enum.map(fn dependency ->
            error(path, :missing_dependency, "unknown step dependency: #{dependency}")
          end)

        self_error =
          if name in dependencies do
            [error(path, :invalid_value, "step cannot depend on itself")]
          else
            []
          end

        missing_errors ++ self_error
      end)

    if errors == [], do: :ok, else: {:error, errors}
  end

  defp topological_sort(steps) do
    index_map = step_index_map(steps)
    name_to_step = Map.new(steps, &{&1.name, &1})

    {in_degree, adjacency} = build_dependency_graph(steps)

    queue = zero_degree_queue(in_degree, index_map)
    sorted_names = do_topological_sort(queue, in_degree, adjacency, index_map, [])

    if length(sorted_names) == map_size(in_degree) do
      ordered_steps = Enum.map(sorted_names, &Map.fetch!(name_to_step, &1))
      {:ok, ordered_steps}
    else
      cycle_nodes =
        in_degree
        |> Enum.filter(fn {_name, degree} -> degree > 0 end)
        |> Enum.map(&elem(&1, 0))
        |> Enum.sort_by(&Map.fetch!(index_map, &1))

      {:error,
       [
         error(
           ["steps"],
           :dependency_cycle,
           "dependency cycle detected involving: #{Enum.join(cycle_nodes, ", ")}"
         )
       ]}
    end
  end

  defp build_dependency_graph(steps) do
    initial_in_degree = Map.new(steps, &{&1.name, 0})

    Enum.reduce(steps, {initial_in_degree, %{}}, fn %DefinitionStep{name: name, depends_on: deps},
                                                    {in_degree, adjacency} ->
      dependencies = Enum.uniq(deps || [])
      in_degree = Map.put(in_degree, name, length(dependencies))

      adjacency =
        Enum.reduce(dependencies, adjacency, fn dependency, acc ->
          Map.update(acc, dependency, [name], &[name | &1])
        end)

      {in_degree, adjacency}
    end)
  end

  defp do_topological_sort([], _in_degree, _adjacency, _index_map, acc), do: Enum.reverse(acc)

  defp do_topological_sort([name | rest], in_degree, adjacency, index_map, acc) do
    children = Map.get(adjacency, name, [])

    {next_in_degree, next_queue} =
      Enum.reduce(children, {in_degree, rest}, fn child, {degree_acc, queue_acc} ->
        degree = Map.fetch!(degree_acc, child) - 1
        degree_acc = Map.put(degree_acc, child, degree)

        queue_acc =
          if degree == 0 do
            enqueue_sorted(queue_acc, child, index_map)
          else
            queue_acc
          end

        {degree_acc, queue_acc}
      end)

    do_topological_sort(next_queue, next_in_degree, adjacency, index_map, [name | acc])
  end

  defp enqueue_sorted(queue, name, index_map) do
    [name | queue]
    |> Enum.uniq()
    |> Enum.sort_by(&Map.fetch!(index_map, &1))
  end

  defp zero_degree_queue(in_degree, index_map) do
    in_degree
    |> Enum.filter(fn {_name, degree} -> degree == 0 end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort_by(&Map.fetch!(index_map, &1))
  end

  defp build_workflow(name, steps) do
    steps
    |> Enum.reduce_while({:ok, Workflow.new(name: name)}, fn step, {:ok, workflow} ->
      case add_step_component(workflow, step) do
        {:ok, next_workflow} -> {:cont, {:ok, next_workflow}}
        {:error, _errors} = error_result -> {:halt, error_result}
      end
    end)
  end

  defp add_step_component(workflow, step) do
    with {:ok, component} <- build_component(step),
         {:ok, next_workflow} <- add_component(workflow, component, step.depends_on || []) do
      {:ok, next_workflow}
    else
      {:error, _errors} = error_result -> error_result
    end
  end

  defp add_component(workflow, component, []), do: safe_add(workflow, component)

  defp add_component(workflow, component, parent_names),
    do: safe_add(workflow, component, to: parent_names)

  defp safe_add(workflow, component, opts \\ []) do
    {:ok, Workflow.add(workflow, component, opts)}
  rescue
    exception ->
      {:error,
       [
         error(
           ["steps"],
           :compile_failed,
           "failed to add component: #{Exception.message(exception)}"
         )
       ]}
  end

  defp build_component(%DefinitionStep{type: type} = step) do
    case StepTypeRegistry.resolve(type) do
      {:ok, {:builtin, :action}} ->
        build_action_component(step)

      {:ok, {:builtin, :agent}} ->
        build_agent_component(step)

      {:ok, {:builtin, :skill}} ->
        build_skill_component(step)

      {:ok, {:builtin, :sub_workflow}} ->
        build_sub_workflow_component(step)

      {:ok, module} when is_atom(module) ->
        build_custom_component(step, module)

      {:error, _reason} ->
        unsupported_step_type_error(step, type)
    end
  end

  defp build_action_component(step) do
    params = %{step: serialize_action_step(step)}
    timeout = step.timeout_ms || 0
    {:ok, ActionNode.new(ExecuteActionStep, params, name: step.name, timeout: timeout)}
  end

  defp build_agent_component(step) do
    params = %{step: serialize_action_step(step)}
    timeout = step.timeout_ms || 0
    {:ok, ActionNode.new(ExecuteAgentStep, params, name: step.name, timeout: timeout)}
  end

  defp build_sub_workflow_component(step) do
    params = %{step: serialize_sub_workflow_step(step)}
    timeout = step.timeout_ms || 0
    {:ok, ActionNode.new(ExecuteSubWorkflowStep, params, name: step.name, timeout: timeout)}
  end

  defp build_skill_component(step) do
    params = %{step: serialize_action_step(step)}
    timeout = step.timeout_ms || 0
    {:ok, ActionNode.new(ExecuteSkillStep, params, name: step.name, timeout: timeout)}
  end

  defp build_custom_component(step, module) do
    params = %{step: serialize_custom_step(step)}
    timeout = step.timeout_ms || 0
    {:ok, ActionNode.new(module, params, name: step.name, timeout: timeout)}
  end

  defp unsupported_step_type_error(%DefinitionStep{name: name}, type) do
    {:error,
     [
       error(
         ["steps", to_string(name), "type"],
         :invalid_value,
         "unsupported step type: #{inspect(type)}"
       )
     ]}
  end

  defp serialize_custom_step(step) do
    Map.from_struct(step)
  end

  defp serialize_action_step(step) do
    step
    |> Map.from_struct()
    |> Map.take([
      :name,
      :type,
      :module,
      :agent,
      :workflow,
      :callback_signal,
      :inputs,
      :outputs,
      :depends_on,
      :async,
      :optional,
      :mode,
      :timeout_ms,
      :max_retries,
      :pre_actions,
      :post_actions,
      :condition,
      :parallel
    ])
  end

  defp serialize_sub_workflow_step(step) do
    step
    |> Map.from_struct()
    |> Map.take([
      :name,
      :type,
      :workflow,
      :inputs,
      :condition,
      :depends_on,
      :timeout_ms
    ])
  end

  defp compile_return(nil), do: %{value: nil, transform: nil}

  defp compile_return(%Definition.Return{value: value, transform: transform}),
    do: %{value: value, transform: transform}

  defp compile_error_handling(nil), do: []
  defp compile_error_handling(error_handling) when is_list(error_handling), do: error_handling
  defp compile_error_handling(_other), do: []

  defp compile_signals(nil), do: nil

  defp compile_signals(%DefinitionSignals{} = signals) do
    %{
      topic: signals.topic,
      publish_events: signals.publish_events
    }
  end

  defp compile_settings(nil), do: nil

  defp compile_settings(%DefinitionSettings{} = settings) do
    %{
      max_concurrency: settings.max_concurrency,
      timeout_ms: settings.timeout_ms,
      retry_policy: compile_retry_policy(settings.retry_policy),
      on_failure: settings.on_failure
    }
  end

  defp compile_retry_policy(nil), do: nil

  defp compile_retry_policy(%DefinitionRetryPolicy{} = retry_policy) do
    %{
      max_retries: retry_policy.max_retries,
      backoff: retry_policy.backoff,
      base_delay_ms: retry_policy.base_delay_ms
    }
  end

  defp step_index_map(steps) do
    steps
    |> Enum.with_index()
    |> Map.new(fn {%DefinitionStep{name: name}, index} -> {name, index} end)
  end

  defp error(path, code, message), do: %ValidationError{path: path, code: code, message: message}
end
