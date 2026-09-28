defmodule Grasp.Index.Templates do
  @moduledoc """
  Builds a definition for every template a module embeds, in the shape
  `Grasp.Index.Extract` returns for the functions it reads from Elixir source.

  Phoenix compiles every file an `embed_templates` pattern matches into a one-argument
  function of the embedding module, named after the basename with its format and engine
  extensions dropped and the embed's `:suffix` appended, and points `@file` at the
  template, so the compiler reports the calls the template makes against the template's own
  path. The pattern is looked for under the embed's `:root`, resolved against the directory
  of the module that embeds it, which is also where it is looked for when no `:root` is
  given. A definition per match is what those
  calls land on, and it gives the template's component tags and the calls written inside
  its interpolations — both read by `Grasp.Index.Extract` — a range a reader can click.
  The whole file is the definition: it spans line 1 to its last line and its source is the
  file's text.

  Only a `.heex` template carries call sites and route sites, for its tags, its
  interpolations and the links and forms it writes alike. HEEx is the engine whose tags
  compile to component calls and whose `{...}` and `<%= ... %>` bodies are Elixir, so an
  `.eex` template is a record with no sites: the calls the tracer reports inside it still
  land on it, and nothing in it is clickable.

  A pattern may reach out of the directory it is written in (`"../shared_html/*"`) but not
  out of the project: every match is expanded to a canonical path, one outside the root is
  dropped, and what the definition carries is the path relative to the root, which is the
  name the index and git both use.
  """

  alias Grasp.Index.Extract

  @doc """
  Definitions for the templates `embeds` match, under the project root `root`.

  `definitions` are the ones already read from the project's Elixir sources: a module that
  writes the function by hand keeps that definition and the template is skipped, and where
  two templates would claim one name — the same basename under two formats — the first
  path wins. A file that cannot be read is reported and skipped.
  """
  @spec definitions(String.t(), [Extract.embed()], [Extract.definition()]) :: [
          Extract.definition()
        ]
  def definitions(root, embeds, definitions) do
    root = Path.expand(root)

    # Every arity a definition answers to, as `Grasp.Index.Join` reaches them: a component
    # written by hand with a default argument still owns the name the template would claim.
    written =
      for definition <- definitions,
          arity <- definition.arities,
          into: MapSet.new(),
          do: {definition.module, definition.name, arity}

    {templates, _claimed} =
      embeds
      |> Enum.flat_map(&paths(root, &1))
      |> Enum.uniq()
      |> Enum.reduce({[], written}, fn {module, suffix, path}, {templates, claimed} ->
        relative = Path.relative_to(path, root)
        name = name(path, suffix)

        if MapSet.member?(claimed, {module, name, 1}) do
          {templates, claimed}
        else
          case File.read(path) do
            {:ok, source} ->
              {[definition(module, name, relative, source) | templates],
               MapSet.put(claimed, {module, name, 1})}

            {:error, reason} ->
              Mix.shell().error("grasp: skipping #{relative}: #{inspect(reason)}")
              {templates, claimed}
          end
        end
      end)

    Enum.reverse(templates)
  end

  # The pattern is looked for under the embed's `:root` — resolved against the directory of
  # the module that embeds it, and that directory itself when there is none — and Phoenix
  # appends the extension of every engine it compiles, so `"greet_html/*"` matches
  # `greet_html/show.html.heex` and not the fixtures or assets sitting beside it. A match is
  # expanded before anything is done with it: a pattern that walks up (`"../shared_html/*"`)
  # would otherwise leave the `..` in the path the record carries, which no path git reports
  # can ever equal, and a pattern that walks out of the project would write a path only this
  # machine could resolve.
  defp paths(root, embed) do
    directory = Path.dirname(Path.join(root, embed.file))
    base = Path.expand(embed.root || directory, directory)

    base
    |> Path.join(embed.pattern <> ".{heex,eex}")
    |> Path.wildcard()
    |> Enum.map(&Path.expand/1)
    |> Enum.filter(&String.starts_with?(&1, root <> "/"))
    |> Enum.sort()
    |> Enum.map(&{embed.module, embed.suffix, &1})
  end

  # `Phoenix.Component.__embed__/2`: the basename without its format and engine extensions,
  # carrying the embed's suffix.
  defp name(path, suffix) do
    path
    |> Path.basename()
    |> Path.rootname()
    |> Path.rootname()
    |> Kernel.<>(suffix || "")
    |> String.to_atom()
  end

  defp definition(module, name, file, source) do
    %{
      module: module,
      name: name,
      arity: 1,
      arities: [1],
      kind: :template,
      file: file,
      start_line: 1,
      end_line: line_count(source),
      source: source,
      # HEEx is the engine whose tags compile to component calls, whose interpolations are
      # Elixir and whose attributes name routes; an EEx template has none of the three.
      call_sites:
        if(Path.extname(file) == ".heex",
          do: Extract.template_sites(source, {1, 0}, nil),
          else: []
        ),
      route_sites:
        if(Path.extname(file) == ".heex",
          do: Extract.template_route_sites(source, {1, 0}, nil),
          else: []
        ),
      double_sites: [],
      head_positions: [],
      head_ranges: [],
      clauses: [],
      arms: []
    }
  end

  # A trailing newline ends the last line rather than opening another, so a template
  # written the way every file should be spans its content and not one line past it.
  defp line_count(source) do
    count = source |> String.split("\n") |> length()

    if String.ends_with?(source, "\n"), do: max(count - 1, 1), else: count
  end
end
