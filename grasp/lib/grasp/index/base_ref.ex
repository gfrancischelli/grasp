defmodule Grasp.Index.BaseRef do
  @moduledoc """
  Resolves a git ref into the commit an index is compared against, the source files that
  differ from it, and the contents those files had at that commit.

  The base commit is `git merge-base REF HEAD`, so a branch whose target has moved on is
  compared against the point the two diverged rather than against work the branch never
  saw. A ref with no common history has no merge base, and the ref's own commit is used
  instead. The result has to look like a commit hash before it is believed: git writes
  diagnostics on stderr and still exits 0 — a refname that is both a tag and a branch is
  the everyday case — and a base commit that is not 40 hex digits would send every later
  command looking for an object that cannot exist.

  The file list is the union of the tracked paths that differ from the base commit and the
  files git reports as untracked, narrowed to the sources the index reads under the
  project's compile paths: `.ex` files and the `.heex` and `.eex` templates they embed.
  Under the test paths the same three kinds are kept, for the support files a test build
  compiles, and so is every `.exs` file, since a project's test pattern and load filters
  decide which of them are tests; which files `mix test` loads is known only once the test
  trace has run, so narrowing them to those is `Grasp.Index.Builder.classify/4`'s business.
  A deleted file stays in the list: its functions still have to be reported as removed.
  Rename detection is off, so a file git would have reported as renamed appears under both
  its old and its new path and keeps the base source it had under the old one. Paths are
  asked for, and resolved, relative to the working directory rather than the repository
  root, so a Mix project sitting in a subdirectory of a larger repository sees the
  project-relative paths the index itself uses.

  Everything goes through `git` as an external command, and only the exit status decides
  whether a command succeeded: stdout is captured on its own so nothing git says can be
  read as a value, paths are read NUL-separated so a name git would otherwise quote or
  break across lines survives, and every failure comes back as an error string a caller
  can print rather than as a silently empty result.
  """

  # Enough to tell a commit hash from anything git decided to say instead.
  @commit ~r/^[0-9a-f]{40}$/

  # What the index extracts definitions from: Elixir sources and the templates a module
  # embeds, which are records of their own.
  @source_extensions [".ex", ".heex", ".eex"]

  @type resolved :: %{
          base_ref: String.t(),
          base_sha: String.t(),
          files: [String.t()],
          base_sources: %{String.t() => String.t()}
        }

  @doc """
  Resolves `ref` against the repository holding `root`.

  `:paths` lists the directories whose sources are of interest, defaulting to `["lib"]`;
  `:test_paths`, defaulting to none, lists the directories whose `.exs` files are too, with
  the sources under them. A file outside both is left out of `:files` and `:base_sources`.
  """
  @spec resolve(String.t(), String.t(), paths: [String.t()], test_paths: [String.t()]) ::
          {:ok, resolved()} | {:error, String.t()}
  def resolve(root, ref, opts \\ []) do
    paths = Keyword.get(opts, :paths, ["lib"])
    test_paths = Keyword.get(opts, :test_paths, [])

    with :ok <- repository(root),
         {:ok, base_sha} <- base_sha(root, ref),
         {:ok, changed} <- changed_files(root, base_sha),
         {:ok, untracked} <- untracked_files(root),
         candidates = Enum.map(changed, fn {_status, path} -> path end) ++ untracked,
         files = sources(candidates, paths, test_paths),
         kept = MapSet.new(files),
         in_base = for({status, path} <- changed, status != "A", path in kept, do: path),
         {:ok, base_sources} <- base_sources(root, base_sha, in_base) do
      {:ok, %{base_ref: ref, base_sha: base_sha, files: files, base_sources: base_sources}}
    end
  end

  defp repository(root) do
    if File.dir?(root) do
      case discard(["rev-parse", "--git-dir"], root) do
        :ok -> :ok
        :error -> {:error, "not a git repository"}
        :no_git -> {:error, "git is not installed"}
      end
    else
      {:error, "not a git repository"}
    end
  end

  defp base_sha(root, ref) do
    result =
      case git(["merge-base", ref, "HEAD"], root) do
        # No merge base means the ref shares no history with HEAD (an orphan branch, a
        # shallow clone); the ref's own commit is the only base there is.
        :error -> git(["rev-parse", "--verify", ref <> "^{commit}"], root)
        other -> other
      end

    case result do
      {:ok, output} -> commit(String.trim(output), ref)
      :error -> {:error, "unknown ref: #{ref}"}
      :no_git -> {:error, "git is not installed"}
    end
  end

  defp commit(sha, ref) do
    if Regex.match?(@commit, sha), do: {:ok, sha}, else: {:error, "could not resolve #{ref}"}
  end

  # Status letter and path per entry. `--no-renames` keeps a rename as the two paths it
  # touches, so the old one still carries its base source instead of reading as an added
  # file; `A` is the one status whose path the base commit does not hold.
  defp changed_files(root, base_sha) do
    args = ["diff", "--name-status", "--no-renames", "--relative", "-z", base_sha]

    case git(args, root) do
      {:ok, output} ->
        {:ok, output |> fields() |> Enum.chunk_every(2) |> Enum.map(&List.to_tuple/1)}

      :error ->
        {:error, "could not diff against #{base_sha}"}

      :no_git ->
        {:error, "git is not installed"}
    end
  end

  defp untracked_files(root) do
    case git(["ls-files", "--others", "--exclude-standard", "-z"], root) do
      {:ok, output} -> {:ok, fields(output)}
      :error -> {:error, "could not list untracked files"}
      :no_git -> {:error, "git is not installed"}
    end
  end

  defp base_sources(root, base_sha, files) do
    Enum.reduce_while(files, {:ok, %{}}, fn file, {:ok, sources} ->
      case git(["show", "#{base_sha}:./#{file}"], root) do
        {:ok, source} -> {:cont, {:ok, Map.put(sources, file, source)}}
        :error -> {:halt, {:error, "could not read #{file} at #{base_sha}"}}
        :no_git -> {:halt, {:error, "git is not installed"}}
      end
    end)
  end

  defp sources(files, paths, test_paths) do
    prefixes = prefixes(paths)
    test_prefixes = prefixes(test_paths)

    files
    # The extensions the index is built from, and no others: a changed `.exs` outside the
    # test paths would carry base definitions no current record could ever answer to, and
    # every one of them would read as a deletion.
    |> Enum.filter(fn file ->
      (Path.extname(file) in @source_extensions and
         String.starts_with?(file, prefixes ++ test_prefixes)) or
        (Path.extname(file) == ".exs" and String.starts_with?(file, test_prefixes))
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp prefixes(roots), do: Enum.map(roots, &(String.trim_trailing(&1, "/") <> "/"))

  defp fields(output), do: String.split(output, "\0", trim: true)

  # Output is parsed, so stderr stays on the user's terminal where git's warnings belong
  # rather than being folded into a value.
  defp git(args, root) do
    case System.cmd("git", args, cd: root) do
      {output, 0} -> {:ok, output}
      {_output, _status} -> :error
    end
  rescue
    ErlangError -> :no_git
  end

  # For a command run only for its exit status, so git's own message about a directory
  # that is not a repository is swallowed rather than printed ahead of ours.
  defp discard(args, root) do
    case System.cmd("git", args, cd: root, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {_output, _status} -> :error
    end
  rescue
    ErlangError -> :no_git
  end
end
