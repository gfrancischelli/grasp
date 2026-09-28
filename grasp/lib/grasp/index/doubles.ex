defmodule Grasp.Index.Doubles do
  @moduledoc """
  Turns a test's Mox expectations into calls on the code they stand in for.

  A Mox mock is declared with `Mox.defmock(Mock, for: Behaviour)`, or a bare
  `defmock(Mock, for: Behaviour)` as a file importing `Mox` writes it, in `test_helper.exs`
  or a test-only support file, and a test sets it
  up with `expect(Mock, :fun, …)` or `stub(Mock, :fun, …)`. The mock stands in for every
  module that implements `Behaviour`, so the test's expectation names code the index holds:
  `Impl.fun` of each implementation. `resolve/4` writes those as calls of kind `:double`,
  each carrying the mock and the behaviour under `:double`.

  The declarations are read by parsing, never by running the file: a `test_helper.exs`
  starts applications and configures the test run, which is nothing an index build may do.
  Module names are read as the file writes them and expanded through its `alias` lines
  (`alias SampleApp.Geo` makes `Geo.Lookup` read as `SampleApp.Geo.Lookup`), which is what
  the compiler does with them. A mock or a behaviour the source computes — a module
  attribute, a variable, a list of behaviours — names nothing a parser can know and is
  skipped.

  `Grasp.Index.Extract` records the expectation sites, as `double_sites` on a definition;
  this module reads them. A site whose mock no declaration names, or whose behaviour no
  indexed module implements, draws nothing.
  """

  alias Grasp.Index.Join

  @typedoc "Mock module name to the behaviour it doubles, both as `inspect/1` writes them."
  @type declarations :: %{String.t() => String.t()}

  @typedoc "A module's short name, as a file's `alias` lines introduce it, to its full name."
  @type aliases :: %{String.t() => String.t()}

  @doc """
  The mocks `sources` declare, each mapped to the behaviour it doubles.

  Every source is parsed and none is evaluated. A source that does not parse declares
  nothing. When two declarations name one mock, the later source's wins, as the later
  `defmock` would at run time.
  """
  @spec declarations([String.t()]) :: declarations()
  def declarations(sources) when is_list(sources) do
    sources
    |> Enum.flat_map(fn source ->
      case Sourceror.parse_string(source) do
        {:ok, ast} -> source_declarations(ast)
        {:error, _reason} -> []
      end
    end)
    |> Map.new()
  end

  @doc """
  The mocks the project at `root` declares where its tests would find them: the
  `test_helper.exs` of each of `test_paths`, which `mix test` runs before any test, and
  `files`, the test-only support files and test files the test trace read.

  Paths are relative to `root`, or absolute. A test path with no `test_helper.exs`, or a
  file that cannot be read, declares nothing. The files are parsed as `declarations/1`
  parses them, and none is run.
  """
  @spec declarations_in(String.t(), [String.t()], [String.t()]) :: declarations()
  def declarations_in(root, test_paths, files) do
    helpers =
      for path <- test_paths,
          helper = Path.expand(Path.join(path, "test_helper.exs"), root),
          File.regular?(helper),
          do: helper

    (helpers ++ Enum.map(files, &Path.expand(&1, root)))
    |> Enum.uniq()
    |> Enum.flat_map(fn file ->
      case File.read(file) do
        {:ok, source} -> [source]
        {:error, _reason} -> []
      end
    end)
    |> declarations()
  end

  defp source_declarations(ast) do
    aliases = aliases(ast)

    {_, found} =
      Macro.prewalk(ast, [], fn node, found ->
        case defmock(node) do
          {mock, behaviour} ->
            with mock when is_binary(mock) <- expand(mock, aliases),
                 behaviour when is_binary(behaviour) <- expand(behaviour, aliases) do
              {node, [{mock, behaviour} | found]}
            else
              _dynamic -> {node, found}
            end

          nil ->
            {node, found}
        end
      end)

    Enum.reverse(found)
  end

  defp defmock({{:., _, [{:__aliases__, _, [:Mox]}, :defmock]}, _meta, args}), do: mock_args(args)
  defp defmock({:defmock, _meta, args}), do: mock_args(args)
  defp defmock(_node), do: nil

  defp mock_args([mock, {:__block__, _, [options]}]) when is_list(options),
    do: mock_args([mock, options])

  defp mock_args([mock, options]) when is_list(options) do
    Enum.find_value(options, fn
      {{:__block__, _, [:for]}, behaviour} -> {mock, behaviour}
      _option -> nil
    end)
  end

  defp mock_args(_args), do: nil

  @doc """
  The aliases a parsed file introduces, each short name mapped to the module it expands to.

  Reads `alias A.B`, `alias A.B, as: C` and `alias A.{B, C}` anywhere in the file, in order,
  so an alias written through an earlier one expands fully. Scope is not followed: an alias
  inside one module reads as the file's, which is what a file declaring its mocks or writing
  its tests needs.
  """
  @spec aliases(Macro.t()) :: aliases()
  def aliases(ast) do
    {_, aliases} =
      Macro.prewalk(ast, %{}, fn
        {:alias, _meta, [target | options]} = node, aliases ->
          {node, Map.merge(aliases, alias_entries(target, options, aliases))}

        node, aliases ->
          {node, aliases}
      end)

    aliases
  end

  defp alias_entries({{:., _, [base, :{}]}, _meta, children}, _options, aliases) do
    with base when is_binary(base) <- expand(base, aliases) do
      for {:__aliases__, _, parts} = child <- children,
          name = expand(child, %{}),
          is_binary(name),
          into: %{},
          do: {parts |> List.last() |> Atom.to_string(), base <> "." <> name}
    else
      _dynamic -> %{}
    end
  end

  defp alias_entries({:__aliases__, _, parts} = target, options, aliases) do
    with full when is_binary(full) <- expand(target, aliases),
         short when is_binary(short) <- alias_as(options, parts) do
      %{short => full}
    else
      _dynamic -> %{}
    end
  end

  defp alias_entries(_target, _options, _aliases), do: %{}

  defp alias_as([options], parts) when is_list(options) do
    Enum.find_value(options, last_part(parts), fn
      {{:__block__, _, [:as]}, {:__aliases__, _, [short]}} when is_atom(short) ->
        Atom.to_string(short)

      _option ->
        nil
    end)
  end

  defp alias_as(_options, parts), do: last_part(parts)

  defp last_part(parts) do
    case List.last(parts) do
      last when is_atom(last) -> Atom.to_string(last)
      _dynamic -> nil
    end
  end

  @doc """
  The full name a literal alias node names under `aliases`, or `nil` for anything else.

  The first segment is looked up, as the compiler looks it up: `Geo.Lookup` under
  `alias SampleApp.Geo` is `SampleApp.Geo.Lookup`. A name written from `Elixir.` is taken as
  it is.
  """
  @spec expand(Macro.t(), aliases()) :: String.t() | nil
  def expand({:__aliases__, _meta, [:"Elixir" | parts]}, _aliases), do: join(parts)

  def expand({:__aliases__, _meta, [first | _] = parts}, aliases) when is_atom(first) do
    with name when is_binary(name) <- join(parts) do
      [head | rest] = String.split(name, ".")

      case Map.fetch(aliases, head) do
        {:ok, full} -> Enum.join([full | rest], ".")
        :error -> name
      end
    end
  end

  def expand(_node, _aliases), do: nil

  defp join(parts) do
    if parts != [] and Enum.all?(parts, &is_atom/1), do: Enum.map_join(parts, ".", &to_string/1)
  end

  @doc """
  Adds a `:double` call to `records` for every target each record's double sites reach.

  `declarations` are `declarations/1`'s. `modules` are the document's modules, in the JSON
  shape `Grasp.Index.Builder.module_json/2` writes: an implementation of a behaviour is a
  module whose `"behaviours"` include it. `functions` are the records the calls may reach —
  the application's — and a target is `Impl.fun/arity` for the arity the site read, or for
  every arity `Impl.fun` has when the site read none; a target no record answers to is not
  written. A record's calls stay sorted as `Grasp.Index.Join` sorts them.
  """
  @spec resolve([map()], declarations(), [map()], [Join.function_record()]) :: [map()]
  def resolve(records, declarations, modules, functions) do
    implementations =
      for module <- modules, behaviour <- Map.get(module, "behaviours", []), reduce: %{} do
        acc -> Map.update(acc, behaviour, [module["name"]], &[module["name"] | &1])
      end

    arities =
      for function <- functions,
          not Map.get(function, :removed, false),
          arity <- function.arities,
          reduce: %{} do
        acc -> Map.update(acc, {function.module, function.name}, [arity], &[arity | &1])
      end

    Enum.map(records, &resolve_record(&1, declarations, implementations, arities))
  end

  defp resolve_record(record, declarations, implementations, arities) do
    case Map.get(record, :double_sites, []) do
      [] ->
        record

      sites ->
        doubles = Enum.flat_map(sites, &calls(&1, declarations, implementations, arities))

        %{
          record
          | calls:
              (record.calls ++ doubles)
              |> Enum.uniq()
              |> Enum.sort_by(&{&1.range.start, &1.target, &1.kind})
        }
    end
  end

  defp calls(site, declarations, implementations, arities) do
    with {:ok, behaviour} <- Map.fetch(declarations, site.mock) do
      for implementation <- implementations |> Map.get(behaviour, []) |> Enum.sort(),
          arity <- implementation |> defined(site.function, arities) |> wanted(site.arity) do
        %{
          target: Join.function_id(implementation, site.function, arity),
          kind: :double,
          range: site.range,
          double: %{mock: site.mock, behaviour: behaviour}
        }
      end
    else
      :error -> []
    end
  end

  defp defined(module, function, arities),
    do: arities |> Map.get({module, function}, []) |> Enum.uniq() |> Enum.sort()

  defp wanted(defined, nil), do: defined
  defp wanted(defined, arity), do: Enum.filter(defined, &(&1 == arity))
end
