defmodule GraspWeb.ChatMarkdown do
  @moduledoc """
  Renders an assistant turn's text — Markdown written by a model — as safe HTML.

  The text is parsed as GitHub-flavoured Markdown (tables, strikethrough, task lists,
  autolinks) and rewritten in two places before it is serialised:

    * a fenced block becomes a `pre.fence` whose body is highlighted by Lumis under the
      language the fence names, so a snippet quoted in the chat reads like the card it was
      taken from. A fence whose language Lumis does not know, and a fence with no language
      at all, is escaped and rendered plain;
    * a `Mod.fun/arity` the index holds becomes a `button.fn` carrying the id in `data-fn`,
      whether it was written in backticks or bare in a sentence, so naming a function in an
      answer is the same gesture as clicking a call site. An id the index does not hold is
      left as the code span or the prose it was written as, since a button that opens
      nothing is worse than no button. A module name the index holds is linked the same
      way when it is written in backticks, and left as prose when it is not, since a
      capitalised word in a sentence is far more often a word than a module. An id inside
      a Markdown link or an autolink is left
      alone too, because a link is already one, as is one in an image's alt text, which is
      an attribute rather than markup by the time it is serialised. An `a` the model wrote
      as raw HTML is not recognised as a link, so an id inside one is still drawn as a
      button.

  Everything the model writes is untrusted, and the sanitiser is the boundary that holds it:
  the serialised HTML passes through MDEx's sanitiser with an explicit allow-list, which
  drops `script` and `style` along with their content, every `on*` handler, every URL scheme
  outside the list and every attribute no tag was granted.

  Among the attributes no tag is granted are all of `phx-*`: this module emits no event
  binding at all. A binding that survived sanitisation would be the model's, not the
  panel's, and could fire any of the LiveView's events from a button the reader cannot tell
  from a function link. A link carries its id in `data-fn` instead, and the `Chat` hook maps
  that one attribute to the one event, so only an id this module wrote reaches the LiveView.

  A rendered answer is memoised: the transcript re-renders on every line the CLI prints, and
  highlighting a large fence costs hundreds of milliseconds. The cache is an ETS table the
  index store owns, as the card highlighter's is, and is emptied whenever the index reloads.
  """

  @extension [strikethrough: true, table: true, autolink: true, tasklist: true]

  # A written id is `Mod.fun/arity`, possibly nested (`A.B.fun/1`) and possibly a predicate
  # or a bang. In prose the same body must not start inside a longer name, so a match is
  # refused after a word character or a dot.
  @function_id ~r{\A(?:[A-Z]\w*\.)+[a-z_]\w*[?!]?/\d+\z}
  @function_id_in_text ~r{(?<![\w.])(?:[A-Z]\w*\.)+[a-z_]\w*[?!]?/\d+}
  @module_name ~r{\A[A-Z]\w*(?:\.[A-Z]\w*)*\z}
  @module_span ~r{`([A-Z]\w*(?:\.[A-Z]\w*)*)`}

  # Fence info strings Lumis does not answer to under the name a writer reaches for.
  @language_aliases %{
    "ex" => "elixir",
    "exs" => "elixir",
    "erl" => "erlang",
    "sh" => "bash",
    "shell" => "bash",
    "console" => "bash"
  }

  @languages_key {__MODULE__, :languages}

  @cache :grasp_chat_markdown_cache
  @cache_limit 500

  @doc """
  The Markdown in `text` as sanitised HTML.

  `known?` decides which function ids and module names become buttons: it is given an id
  exactly as the text wrote it and answers whether the index holds a function or a module
  under it, following the arities a default argument declares. `known/1` builds it for an
  index.
  """
  @spec render(String.t(), (String.t() -> boolean())) :: Phoenix.HTML.safe()
  def render(text, known?) when is_binary(text) and is_function(known?, 1) do
    {:safe, cached(text, known?, fn -> html(text, known?) end)}
  end

  @doc """
  The `known?` an index answers for `render/2`: whether it holds a function under the id,
  followed through the arities a default argument declares as a call site on a card is, or
  a module under the name. With no index nothing is linkable, since every button would open
  a card of nothing.
  """
  @spec known(Grasp.Index.t() | nil) :: (String.t() -> boolean())
  def known(nil), do: fn _id -> false end

  def known(%Grasp.Index{} = index),
    do: &match?({:ok, _record}, Grasp.Index.fetch_record(index, &1))

  @doc """
  Creates the render cache unless it exists; the calling process owns it.

  Returns `:ok` whether or not it had to create the table.
  """
  @spec ensure_cache() :: :ok
  def ensure_cache do
    if :ets.whereis(@cache) == :undefined do
      :ets.new(@cache, [:set, :public, :named_table, read_concurrency: true])
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "Drops every memoised render; a no-op when the cache does not exist."
  @spec clear_cache() :: :ok
  def clear_cache do
    if :ets.whereis(@cache) != :undefined, do: :ets.delete_all_objects(@cache)
    :ok
  end

  defp html(text, known?) do
    text
    |> MDEx.parse_document!(extension: @extension)
    |> rewrite(known?)
    |> MDEx.to_html!(render: [unsafe: true], sanitize: allow_list())
  end

  # A link's text is already a link, so nothing under one is rewritten: a button nested in an
  # `a` is markup no browser agrees on, and a click on it would both open the card and
  # navigate the tab away from the canvas. Leaving a subtree alone is why the tree is walked
  # here rather than with `MDEx.traverse_and_update/2`, which rewrites a node's children
  # before the node itself and so cannot be told to stop.
  defp rewrite(%MDEx.Link{} = node, _known?), do: node

  # An image's children are its alt text, and alt text is an attribute once serialised: a
  # button written into one reaches the reader as escaped characters rather than as a link.
  defp rewrite(%MDEx.Image{} = node, _known?), do: node

  defp rewrite(%MDEx.CodeBlock{info: info, literal: code}, _known?),
    do: %MDEx.HtmlBlock{literal: fence_html(info, code)}

  defp rewrite(%MDEx.Code{literal: id} = node, known?) do
    if (function_id?(id) or module_name?(id)) and known?.(id),
      do: %MDEx.HtmlInline{literal: link_html(id)},
      else: node
  end

  defp rewrite(%MDEx.Text{literal: text} = node, known?), do: link_prose(node, text, known?)

  defp rewrite(%{nodes: nodes} = node, known?),
    do: %{node | nodes: Enum.map(nodes, &rewrite(&1, known?))}

  defp rewrite(node, _known?), do: node

  # A Text node is replaced whole rather than split in place: the walk maps one node to one
  # node, so the linked ids and the text around them are handed back as a single run of
  # inline HTML, with everything that is not an id escaped as it was written.
  defp link_prose(node, text, known?) do
    parts = Regex.split(@function_id_in_text, text, include_captures: true)

    if Enum.any?(parts, &linkable?(&1, known?)) do
      literal =
        Enum.map_join(parts, fn part ->
          if linkable?(part, known?), do: link_html(part), else: escape(part)
        end)

      %MDEx.HtmlInline{literal: literal}
    else
      node
    end
  end

  defp linkable?(text, known?), do: function_id?(text) and known?.(text)

  defp function_id?(text), do: Regex.match?(@function_id, text)

  defp module_name?(text), do: Regex.match?(@module_name, text)

  defp link_html(id) do
    escaped = escape(id)

    ~s(<button type="button" class="fn" data-fn="#{escaped}">#{escaped}</button>)
  end

  # One entry per answer, since a transcript re-renders on every line the CLI prints and a
  # code-heavy answer costs hundreds of milliseconds to highlight. The key is the text and
  # the ids in it the index holds: the same answer read against an index that resolves a
  # different set of links is a different entry, and two answers that differ at all hash
  # apart. Without the table — a unit test with no store running — every call renders.
  defp cached(text, known?, render) do
    if :ets.whereis(@cache) == :undefined do
      render.()
    else
      key = {:erlang.phash2(text), byte_size(text), links(text, known?)}

      case :ets.lookup(@cache, key) do
        [{^key, html}] ->
          html

        [] ->
          html = render.()
          # A session runs for hours and every answer is a new entry, so the table is emptied
          # rather than grown without end; a dropped entry costs one re-render.
          if :ets.info(@cache, :size) >= @cache_limit, do: :ets.delete_all_objects(@cache)
          :ets.insert(@cache, {key, html})
          html
      end
    end
  end

  # Which ids written anywhere in the answer the index holds, and which module names written
  # in backticks, each in the order they were written. This is everything the index
  # contributes to the rendering; a fence and a link resolve no ids, so counting them here
  # only costs an entry that is never reused.
  defp links(text, known?) do
    functions = @function_id_in_text |> Regex.scan(text) |> List.flatten()
    modules = @module_span |> Regex.scan(text, capture: :all_but_first) |> List.flatten()
    {Enum.filter(functions, known?), Enum.filter(modules, known?)}
  end

  # Lumis answers for a language it does not know by highlighting nothing rather than by
  # failing, so the language is resolved before the call and an unresolved fence is escaped
  # instead. The highlighter returns a `pre > code` of its own; only its lines are kept, so
  # the fence carries this panel's class and the language it was rendered under.
  defp fence_html(info, code) do
    case language(info) do
      nil ->
        "<pre><code>#{escape(code)}</code></pre>"

      language ->
        case highlighted_lines(code, language) do
          {:ok, lines} ->
            ~s(<pre class="fence" data-lang="#{escape(language)}"><code>#{lines}</code></pre>)

          :error ->
            "<pre><code>#{escape(code)}</code></pre>"
        end
    end
  end

  defp highlighted_lines(code, language) do
    case Lumis.highlight(code, formatter: {:html_linked, language: language}) do
      {:ok, html} ->
        {:ok,
         html
         |> LazyHTML.from_fragment()
         |> LazyHTML.query("pre > code")
         |> LazyHTML.child_nodes()
         |> LazyHTML.to_html()}

      _other ->
        :error
    end
  rescue
    _error -> :error
  catch
    _kind, _reason -> :error
  end

  # The language the fence's info string names, or nil when the highlighter has no grammar
  # for it. Only the first word counts: a fence may carry attributes after its language.
  defp language(info) do
    name =
      info
      |> to_string()
      |> String.split(~r/\s+/, parts: 2)
      |> hd()
      |> String.downcase()

    name = Map.get(@language_aliases, name, name)

    if MapSet.member?(languages(), name), do: name
  end

  # Every grammar name Lumis answers to, held in persistent term: the list is fixed for the
  # life of the node and a transcript re-renders on every line the CLI prints.
  defp languages do
    case :persistent_term.get(@languages_key, nil) do
      nil ->
        names =
          Lumis.available_languages()
          |> Enum.flat_map(&[&1.id | List.wrap(&1.aliases)])
          |> MapSet.new()

        :persistent_term.put(@languages_key, names)
        names

      names ->
        names
    end
  end

  # Additions to MDEx's defaults, not a replacement for them: the sanitiser's own per-tag
  # lists still apply, so `div` and `span` also keep `data-line`, `code` keeps `translate`
  # and `tabindex`, and `lang` and `title` stay allowed on everything. What is added is the
  # `button` a function link is drawn as, the `data-lang` naming a fence's grammar, and the
  # disabled checkbox a task list draws — an `input` allowed nothing but its state, in a
  # panel that has no form to submit it to. `style` is taken back off `div`, `pre` and
  # `span`, since nothing here emits one and a panel floating over the canvas is a place
  # inline CSS could be aimed at.
  #
  # No `phx-` attribute is allowed on any tag, which is the boundary that matters: the model
  # writes this HTML, and an event binding that survived would let it fire any of the
  # LiveView's events on a click the reader cannot tell from a link this module wrote. The
  # id a function link carries is a `data-fn` the `Chat` hook reads, and the hook pushes the
  # one event it knows.
  defp allow_list do
    MDEx.Document.default_sanitize_options()
    |> Keyword.put(:add_tags, ["button", "input"])
    |> Keyword.put(:add_tag_attributes, %{
      "button" => ["type", "class", "data-fn"],
      "input" => ["type", "checked", "disabled"],
      "pre" => ["class", "data-lang"],
      "code" => ["class"],
      "div" => ["class"],
      "span" => ["class"]
    })
    |> Keyword.put(:rm_tag_attributes, %{
      "div" => ["style"],
      "pre" => ["style"],
      "span" => ["style"]
    })
  end

  defp escape(text), do: text |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end
