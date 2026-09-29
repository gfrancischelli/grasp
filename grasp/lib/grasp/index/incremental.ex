defmodule Grasp.Index.Incremental do
  @moduledoc """
  Rewrites the parts of an index document that a handful of changed files describe,
  leaving every other record exactly as it was.

  `Grasp.Reindexer` calls this after the host's code reloader has recompiled what a save
  touched. The stages are the ones `Grasp.Index.Builder.run/1` walks for the whole
  project — extract, join, entry points, classify — run over the changed files only, so a
  record this produces has the same shape as a record the full build writes.

  Which files count as changed is widened before anything is read. A template is compiled
  into the module that embeds it, so a saved `.heex` and the `.ex` holding its
  `embed_templates` have to move together: a changed template pulls in the file of the
  module that embeds it, and a changed module pulls in the templates it already owns. The
  `.ex` files in that set are re-extracted, the templates are rebuilt from the embeds
  those files declare, and the tracer events of any other file are ignored — they describe
  functions this update is not rebuilding.

  Calls reaching out of the changed files still resolve, because the ids of the records
  being kept are handed to `Grasp.Index.Join.join/3`: without them a hidden call into an
  untouched module would read as a call into nothing and disappear from the graph.

  ## Events and the file they are joined to

  A full build compiles and reads in one breath, so an event and the source it came from
  always agree. Here they need not: the events were recorded by a compile that finished
  some time ago, and the file may have been saved again since. Two rules keep that from
  inventing calls.

    * An event carrying a column that lands on no call site is **dropped**, where a full
      build keeps it as a hidden call (`unmatched_positions: :drop`). In a full build such
      an event came from macro-generated code and the call is real; here it is at least as
      likely to be an event pointing at a line that has moved, and a call the reader cannot
      find anywhere is worse than one that is missing.
    * An event older than the mtime of the file it names describes a version of that file
      that is no longer on disk, and `Grasp.Reindexer` drops it before calling this
      module. A file left with no events at all is not rebuilt: a record built from an
      empty event set would claim the function calls nothing.

  A column-less event is placed by name on a call site of its own line before the
  hidden-call rule is consulted, here as in a full build. That is safe with events this old
  because the mtime rule above has already dropped the stale ones, so the line such an event
  claims is a line of the source this update is reading.

  Classification is per file, against the base commit the document was built with: the
  base contents of the changed files come from `git show`, and a file the base does not
  hold compares against an empty string, which is how `Grasp.Index.Changes` recognises a
  file the branch added. With no base commit, records are left `"unchanged"`. The modules of
  the rebuilt files are read again, moduledoc included, and classified by their moduledocs
  against the same base contents; when the base cannot be read, or there is none, a module
  keeps the `change`, `base_source` and `base_doc` the document held for its name.

  Entry points and module behaviours are recomputed from the modules the VM has loaded. A
  VM that cannot see the application at all keeps what the document already held, so
  reading a document built elsewhere does not empty its sidebar. Either way they are known
  before the records are written out, because every record is resolved against them:
  `Grasp.Index.Resolve` matches a template's links and an enqueueing call against the
  routes and workers among the entry points. Both the rebuilt records and the kept ones go
  through it — the document carries each record's own inputs, so a route added to or
  removed from the router, or a worker added or dropped, moves the edges of a record whose
  file this update did not touch. A document written without those inputs has none to
  resolve, and its kept records stand until the index is next built in full.

  ## What it cannot see

  The update is scoped to files, and that is also its limit.

    * A function that moved from one file to another is removed from the file it left only
      when that file is in the changed set too. A move that recompiles only one of the two
      leaves the record in the other, and the id is briefly held twice.
    * A file that no longer exists drops its definitions, but only if something still
      names it — the compiler reports no events for a deleted file, so a deletion is seen
      through the modules that used to call into it.
    * Entry points are recomputed from the modules loaded in the running VM, so a route
      added to a router the reloader has not compiled yet is not there.
    * A template file added on its own, with no change to the module whose
      `embed_templates` matches it, is not seen: the widening starts from the template
      records the document already holds, and a template nothing has indexed yet has none.
    * A file that will not parse keeps the records the last build gave it, and the templates
      it embeds keep theirs. A save caught half-written is the common case, and emptying a
      file from the canvas until the next compile would be worse than showing it as it last
      stood.
    * Which files are compiled at all is fixed at the document's `elixirc_paths`.

  `mix grasp.index` is the answer to each of those: it is the full build, and it stays.
  """

  require Logger

  alias Grasp.Index.{Builder, Changes, EntryPoints, Join, Resolve, Templates}

  @type base_context :: %{root: String.t(), base_sha: String.t(), paths: [String.t()]}

  @doc """
  Merges the changed files into `document` and returns the new document.

  `changed_files` are project-relative paths under `root`, `events` the tracer events the
  compile produced (events naming other files are dropped), and `base_ctx` either `nil` or
  a map carrying the repository `:root`, the `:base_sha` to compare against and the
  project's compile `:paths`.
  """
  @spec update(
          map(),
          String.t(),
          [String.t()],
          [Grasp.Index.Tracer.event()],
          base_context() | nil
        ) ::
          {:ok, map()} | {:error, term()}
  def update(document, root, changed_files, events, base_ctx) do
    project = document["project"] || %{}
    paths = project["elixirc_paths"] || ["lib"]
    {changed, owners} = widen(document, changed_files)

    sources = changed |> Enum.filter(&source?(root, &1)) |> Enum.sort()
    extracted = Builder.extract(root, sources)
    report_failures(extracted.failures)

    templates = Templates.definitions(root, extracted.embeds, extracted.definitions)

    definitions = extracted.definitions ++ templates

    rebuilt =
      changed
      |> MapSet.difference(unreadable(extracted.failures, owners))
      |> MapSet.union(MapSet.new(templates, & &1.file))

    kept = Enum.reject(document["functions"] || [], &MapSet.member?(rebuilt, &1["file"]))

    joined =
      Join.join(definitions, events_for(events, definitions),
        known_ids: ids(kept),
        unmatched_positions: :drop
      )

    {records, rebuilt_modules} =
      classify(joined, extracted.modules, rebuilt, base_ctx, paths, document)

    kept_modules = Enum.reject(document["modules"] || [], &MapSet.member?(rebuilt, &1["file"]))

    {entry_points, behaviours} =
      detect(document, project["app"], MapSet.union(ids(kept), record_ids(records)))

    refreshed = Enum.map(kept, &Resolve.refresh(&1, entry_points))

    functions =
      records
      |> Resolve.resolve(entry_points)
      |> Enum.map(&Builder.function_json/1)
      |> then(&sort_functions(refreshed ++ &1))

    modules =
      rebuilt_modules
      |> Enum.map(&Builder.module_json(&1, behaviours))
      |> preserve_modules(document)
      |> then(&live_or_removed(kept_modules ++ &1))
      |> sort_modules()

    {:ok,
     document
     |> Map.put("generated_at", timestamp())
     |> Map.put("functions", functions)
     |> Map.put("modules", modules)
     |> Map.put("entry_points", entry_points)}
  rescue
    error -> {:error, error}
  end

  # A VM that cannot see the application — one where the app's name is not an atom, or its
  # modules are not in the code path — has nothing to say about entry points, which is not
  # the same as a project whose routers lost their routes. The document keeps what the full
  # build found there.
  defp detect(document, app, identifiers) do
    app = app_name(app)

    if EntryPoints.available?(app) do
      detected = EntryPoints.detect(app, identifiers)
      report_skipped(detected.skipped)
      {Enum.map(detected.entry_points, &Builder.entry_point_json/1), detected.behaviours}
    else
      {document["entry_points"] || [],
       Map.new(document["modules"] || [], &{&1["name"], &1["behaviours"] || []})}
    end
  end

  # An order of the document's own — by file, then by where in the file the record starts —
  # so an update puts a rebuilt record back where it was instead of appending it, and two
  # updates of the same project produce the same document. It is not the order a full build
  # writes, which is every `.ex` record, then the templates, then the removed records.
  defp sort_functions(functions),
    do: Enum.sort_by(functions, &{&1["file"], &1["span"]["start_line"], &1["id"]})

  defp sort_modules(modules), do: Enum.sort_by(modules, &{&1["file"], &1["line"], &1["name"]})

  # Every id the given document records answer to. A removed record describes a function
  # the base commit had and this project no longer defines, so nothing may resolve to it.
  defp ids(records) do
    for record <- records,
        record["removed"] != true,
        arity <- record["arities"],
        into: MapSet.new(),
        do: Join.function_id(record["module"], record["name"], arity)
  end

  # The same set, read off the records this update has just built, which are still maps
  # with atom keys: entry points are detected before those records become JSON, because
  # resolving their route sites needs the routes detection found.
  defp record_ids(records) do
    for record <- records,
        not Map.get(record, :removed, false),
        arity <- record.arities,
        into: MapSet.new(),
        do: Join.function_id(record.module, record.name, arity)
  end

  # A template is compiled into the module that embeds it and reported under its own path,
  # so neither side can be rebuilt without the other: the module's embeds are where the
  # template definition comes from, and the template's text is what the module's record
  # points at.
  defp widen(document, changed_files) do
    changed = MapSet.new(changed_files)
    module_files = Map.new(document["modules"] || [], &{&1["name"], &1["file"]})

    Enum.reduce(document["functions"] || [], {changed, %{}}, fn record, {acc, owners} ->
      embedding = Map.get(module_files, record["module"])

      cond do
        record["kind"] != "template" or is_nil(embedding) ->
          {acc, owners}

        MapSet.member?(changed, record["file"]) ->
          {MapSet.put(acc, embedding), Map.put(owners, record["file"], embedding)}

        MapSet.member?(changed, embedding) ->
          {MapSet.put(acc, record["file"]), Map.put(owners, record["file"], embedding)}

        true ->
          {acc, owners}
      end
    end)
  end

  defp source?(root, file),
    do: Path.extname(file) == ".ex" and File.regular?(Path.join(root, file))

  defp events_for(events, definitions) do
    files = MapSet.new(definitions, & &1.file)
    Enum.filter(events, &MapSet.member?(files, &1.file))
  end

  defp report_failures([]), do: :ok

  defp report_failures(failures) do
    for %{file: file, reason: reason} <- failures do
      Logger.warning(
        "grasp: #{file} could not be read (#{inspect(reason)}); its records are left as " <>
          "the last build wrote them"
      )
    end

    :ok
  end

  # A file that would not parse keeps the records it has: dropping them would empty it from
  # the canvas the moment a save left it half-written, and the next save that compiles is
  # what rebuilds it. A template goes with the module that embeds it, because its definition
  # comes from that module's embeds and there are none to be had.
  defp unreadable(failures, owners) do
    failed = MapSet.new(failures, & &1.file)

    for {template, owner} <- owners,
        MapSet.member?(failed, owner),
        into: failed,
        do: template
  end

  defp report_skipped([]), do: :ok

  defp report_skipped(views),
    do:
      Logger.debug("grasp: live routes skipped, no indexed functions: #{Enum.join(views, ", ")}")

  # Modules come back unclassified whenever the functions are not classified against the
  # base, and `preserve_modules/3` gives them what the document held.
  defp classify(records, modules, _rebuilt, nil, _paths, _document), do: {records, modules}

  defp classify(records, modules, rebuilt, base_ctx, paths, document) do
    case compared_sources(base_ctx, rebuilt) do
      {:ok, compared} ->
        {Changes.classify(records, compared, paths),
         Changes.classify_modules(modules, compared, paths)}

      :error ->
        Logger.warning(
          "grasp: could not read #{base_ctx.base_sha} in #{base_ctx.root}; the files just " <>
            "rebuilt keep the classification they had"
        )

        {preserve(records, document), modules}
    end
  end

  # A rebuilt module left unclassified keeps the `change`, `base_source` and
  # `base_doc` its name had in the document, and a module the document never classified
  # stays unclassified. A removed module record describes a module the base had and is
  # never what a defined module keeps.
  defp preserve_modules(modules, document) do
    previous =
      for module <- document["modules"] || [],
          module["removed"] != true,
          Map.has_key?(module, "change"),
          into: %{},
          do: {module["name"], module}

    Enum.map(modules, fn module ->
      case {Map.has_key?(module, "change"), Map.fetch(previous, module["name"])} do
        {false, {:ok, kept}} ->
          module
          |> Map.merge(Map.take(kept, ~w(change base_source base_doc)))
          |> Map.put("removed", false)

        _classified_or_new ->
          module
      end
    end)
  end

  # A module this update defines is never also a removed record: a removed record left in a
  # file it did not rebuild names a module that is back.
  defp live_or_removed(modules) do
    live =
      for module <- modules, module["removed"] != true, into: MapSet.new(), do: module["name"]

    Enum.reject(modules, &(&1["removed"] == true and MapSet.member?(live, &1["name"])))
  end

  # The base commit is checked once, before any path is asked for. That is what tells an
  # absent path — a file this branch added, which `Grasp.Index.Changes` recognises by an
  # empty base source — apart from a git that cannot answer at all, where reading every
  # failure as "absent" would mark the whole project added.
  defp compared_sources(base_ctx, rebuilt) do
    if commit?(base_ctx) do
      Enum.reduce_while(rebuilt, {:ok, %{}}, fn file, {:ok, sources} ->
        case base_source(base_ctx, file) do
          {:ok, source} -> {:cont, {:ok, Map.put(sources, file, source)}}
          :error -> {:halt, :error}
        end
      end)
    else
      :error
    end
  end

  defp commit?(base_ctx),
    do: match?({_output, 0}, git(base_ctx, ["cat-file", "-e", "#{base_ctx.base_sha}^{commit}"]))

  defp base_source(base_ctx, file) do
    object = "#{base_ctx.base_sha}:./#{file}"

    case git(base_ctx, ["cat-file", "-e", object]) do
      {_output, 0} -> show(base_ctx, object)
      {_output, _status} -> {:ok, ""}
      :no_git -> :error
    end
  end

  # `show` is the one command whose output is a value, so its stderr is left alone: a
  # warning folded into stdout would be read as part of the file.
  defp show(base_ctx, object) do
    case System.cmd("git", ["show", object], cd: base_ctx.root) do
      {source, 0} -> {:ok, source}
      _failed -> :error
    end
  rescue
    ErlangError -> :error
  end

  # Run for the exit status alone, with git's own complaints swallowed: a file this branch
  # added would otherwise write a fatal error into the host's console on every save.
  defp git(base_ctx, args) do
    System.cmd("git", args, cd: base_ctx.root, stderr_to_stdout: true)
  rescue
    ErlangError -> :no_git
  end

  # A record the document already classified keeps what it was told; one the file has only
  # just gained has nothing to keep and reads as untouched, which is the reading that
  # claims the least. `"removed"` is never carried over: these records are definitions the
  # project holds, and the removed record the id once had described a function it did not.
  defp preserve(records, document) do
    previous = Map.new(document["functions"] || [], &{&1["id"], &1})

    Enum.map(records, fn record ->
      kept = Map.get(previous, record.id, %{})

      {change, base_source} =
        case Map.get(kept, "change") do
          change when change in [nil, "removed"] -> {"unchanged", nil}
          change -> {change, Map.get(kept, "base_source")}
        end

      Map.merge(record, %{change: change, base_source: base_source, removed: false})
    end)
  end

  defp app_name(nil), do: nil

  defp app_name(app) when is_binary(app) do
    String.to_existing_atom(app)
  rescue
    ArgumentError -> nil
  end

  defp timestamp,
    do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
end
