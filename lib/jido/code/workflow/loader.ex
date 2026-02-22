defmodule Jido.Code.Workflow.Loader do
  @moduledoc """
  Loads markdown workflow definitions and validates them into typed contracts.
  """

  alias Jido.Code.Workflow.Definition
  alias Jido.Code.Workflow.MarkdownParser
  alias Jido.Code.Workflow.SchemaValidator
  alias Jido.Code.Workflow.ValidationError
  alias Jido.Code.Workflow.Validator

  @spec load_file(Path.t()) :: {:ok, Definition.t()} | {:error, [ValidationError.t()]}
  def load_file(path) when is_binary(path) do
    with {:ok, parsed} <- MarkdownParser.parse_file(path),
         :ok <- SchemaValidator.validate_workflow(parsed) do
      Validator.validate(parsed)
    end
  end

  @spec load_markdown(binary()) :: {:ok, Definition.t()} | {:error, [ValidationError.t()]}
  def load_markdown(markdown) when is_binary(markdown) do
    with {:ok, parsed} <- MarkdownParser.parse(markdown),
         :ok <- SchemaValidator.validate_workflow(parsed) do
      Validator.validate(parsed)
    end
  end
end
