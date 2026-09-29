defmodule Grasp.MCP.Tools.GetModule do
  @moduledoc """
  Read one module of the indexed project: where it is defined, the behaviours it declares,
  and its moduledoc — the text, whether it is `@moduledoc false`, its change against the
  base ref, and the base side's text when the branch modified or removed it.

  A module's moduledoc says what its functions are for, so it is the thing to read before
  explaining them, and a moduledoc the branch left standing while changing what the module
  does is a finding in its own right.
  """

  use Anubis.Server.Component, type: :tool

  alias Grasp.MCP.Tools

  schema do
    field(:name, :string,
      required: true,
      description: "The module's name, as in `SampleApp.Greeter`"
    )
  end

  @impl true
  def execute(%{name: name}, frame) do
    with {:ok, index} <- Tools.index(),
         {:ok, record} <- Tools.fetch_module(index, name) do
      Tools.reply(frame, %{
        "name" => record["name"],
        "file" => record["file"],
        "line" => record["line"],
        "behaviours" => record["behaviours"] || [],
        "doc" => text(record["doc"]),
        "hidden" => hidden?(record["doc"]),
        "change" => record["change"],
        "base_doc" => base_doc(record)
      })
    else
      {:error, reason} -> Tools.error(frame, reason)
    end
  end

  defp text(%{"text" => text}) when is_binary(text), do: text
  defp text(_doc), do: nil

  defp hidden?(%{"hidden" => true}), do: true
  defp hidden?(_doc), do: false

  defp base_doc(%{"change" => change} = record) when change in ["modified", "removed"],
    do: text(record["base_doc"])

  defp base_doc(_record), do: nil
end
