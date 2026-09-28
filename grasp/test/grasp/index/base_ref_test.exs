defmodule Grasp.Index.BaseRefTest do
  use ExUnit.Case, async: false

  alias Grasp.Index.{BaseRef, Builder, Extract, Join}

  setup do
    root = repository!()

    write!(root, "lib/a.ex", "defmodule A do\n  def f, do: :f\nend\n")
    write!(root, "lib/keep.ex", "defmodule Keep do\n  def k, do: :k\nend\n")
    git!(root, ["add", "."])
    git!(root, ["commit", "-q", "-m", "base"])
    git!(root, ["tag", "base"])
    # A tag and a branch of the same name: git warns about the ambiguity on stderr and
    # resolves the ref anyway, which is how a diagnostic ends up where a sha is expected.
    git!(root, ["branch", "base"])

    write!(root, "lib/a.ex", "defmodule A do\n  def f, do: :changed\nend\n")
    write!(root, "lib/b.ex", "defmodule B do\n  def g, do: :g\nend\n")
    File.rm!(Path.join(root, "lib/keep.ex"))
    write!(root, "README.md", "# readme\n")

    %{root: root, base_sha: git!(root, ["rev-parse", "refs/tags/base^{commit}"])}
  end

  test "resolves the base commit, the changed sources and their base contents", context do
    assert {:ok, resolved} = BaseRef.resolve(context.root, "base")

    assert resolved.base_ref == "base"
    assert resolved.base_sha == context.base_sha
    assert resolved.base_sha =~ ~r/^[0-9a-f]{40}$/
    assert resolved.files == ["lib/a.ex", "lib/b.ex", "lib/keep.ex"]
    assert resolved.base_sources |> Map.keys() |> Enum.sort() == ["lib/a.ex", "lib/keep.ex"]
    assert resolved.base_sources["lib/a.ex"] == "defmodule A do\n  def f, do: :f\nend\n"
    assert resolved.base_sources["lib/keep.ex"] =~ "def k, do: :k"
  end

  test "keeps only the sources the index reads under the given paths", context do
    write!(context.root, "test/support/a.ex", "defmodule ASupport do\nend\n")
    write!(context.root, "test/a_test.exs", "defmodule ATest do\nend\n")
    write!(context.root, "lib/page_html/show.html.heex", "<p>hello</p>\n")

    assert {:ok, resolved} = BaseRef.resolve(context.root, "base", paths: ["lib", "test"])

    assert resolved.files == [
             "lib/a.ex",
             "lib/b.ex",
             "lib/keep.ex",
             "lib/page_html/show.html.heex",
             "test/support/a.ex"
           ]
  end

  @base_test ~S"""
  defmodule ATest do
    use ExUnit.Case

    describe "f/0" do
      test "answers f" do
        assert A.f() == :f
      end

      @tag :slow
      test "is gone" do
        assert true
      end
    end
  end
  """

  @head_test ~S"""
  defmodule ATest do
    use ExUnit.Case

    describe "f/0" do
      test "answers f" do
        assert A.f() == :changed
      end
    end
  end
  """

  @deleted_test ~S"""
  defmodule CTest do
    use ExUnit.Case

    test "is deleted" do
      assert true
    end
  end
  """

  @added_test ~S"""
  defmodule BTest do
    use ExUnit.Case

    test "answers g" do
      assert B.g() == :g
    end
  end
  """

  test "reads the test files under the test paths at the base and classifies their tests" do
    root = repository!()
    write!(root, "lib/a.ex", "defmodule A do\n  def f, do: :f\nend\n")
    write!(root, "test/a_test.exs", @base_test)
    write!(root, "test/test_helper.exs", "ExUnit.start()\n")
    write!(root, "test/c_test.exs", @deleted_test)
    write!(root, "test/support/case.ex", "defmodule Case do\n  def c, do: :c\nend\n")
    write!(root, "test/fixtures/x.ex", "defmodule X do\n  def x, do: :x\nend\n")

    write!(
      root,
      "test/fixtures/app/test/app_test.exs",
      "defmodule AppTest do\n  use ExUnit.Case\n  test \"x\", do: :ok\nend\n"
    )

    git!(root, ["add", "."])
    git!(root, ["commit", "-q", "-m", "base"])

    write!(root, "test/a_test.exs", @head_test)
    write!(root, "test/b_test.exs", @added_test)
    write!(root, "test/test_helper.exs", "ExUnit.start(exclude: :slow)\n")
    write!(root, "test/fixtures/data.exs", "%{}\n")
    write!(root, "test/fixtures/x.ex", "defmodule X do\n  def y, do: :y\nend\n")
    write!(root, "test/support/case.ex", "defmodule Case do\n  def d, do: :d\nend\n")
    File.rm!(Path.join(root, "test/c_test.exs"))
    File.rm!(Path.join(root, "test/fixtures/app/test/app_test.exs"))

    assert {:ok, lib_only} = BaseRef.resolve(root, "HEAD")
    assert lib_only.files == []

    assert {:ok, base} = BaseRef.resolve(root, "HEAD", test_paths: ["test"])

    assert base.files == [
             "test/a_test.exs",
             "test/b_test.exs",
             "test/c_test.exs",
             "test/fixtures/app/test/app_test.exs",
             "test/fixtures/data.exs",
             "test/fixtures/x.ex",
             "test/support/case.ex",
             "test/test_helper.exs"
           ]

    assert base.base_sources["test/a_test.exs"] == @base_test

    records =
      [
        {"test/a_test.exs", @head_test},
        {"test/b_test.exs", @added_test},
        {"test/support/case.ex", "defmodule Case do\n  def d, do: :d\nend\n"}
      ]
      |> Enum.flat_map(fn
        {file, source} ->
          {:ok, %{definitions: definitions}} = Extract.extract(source, file)
          Join.join(definitions, [])
      end)

    traced = %{
      paths: ["test"],
      files: ["test/a_test.exs", "test/b_test.exs", "test/support/case.ex", "test/c_test.exs"]
    }

    by_id = records |> Builder.classify(base, ["lib"], traced) |> Map.new(&{&1.id, &1})

    assert %{change: "modified", base_source: modified_base} =
             by_id[~S|ATest."test f/0 answers f"/1|]

    assert modified_base =~ "assert A.f() == :f"

    assert %{change: "added", base_source: nil} = by_id[~S|BTest."test answers g"/1|]

    assert %{change: "removed", removed: true, base_source: removed_base, test: test} =
             by_id[~S|ATest."test f/0 is gone"/1|]

    assert removed_base =~ "test \"is gone\""
    assert test == %{describe: "f/0", name: "is gone", tags: ["slow"]}

    assert %{change: "removed", test: %{describe: nil, name: "is deleted"}} =
             by_id[~S|CTest."test is deleted"/1|]

    assert %{change: "added"} = by_id["Case.d/0"]
    assert %{change: "removed"} = by_id["Case.c/0"]

    refute Map.has_key?(by_id, ~S|AppTest."test x"/1|)
    refute Map.has_key?(by_id, "X.x/0")
    refute Enum.any?(by_id, fn {_id, record} -> record.file == "test/fixtures/x.ex" end)
  end

  test "lists both paths of a renamed file so the old one keeps its base source", context do
    git!(context.root, ["mv", "lib/a.ex", "lib/renamed.ex"])

    assert {:ok, resolved} = BaseRef.resolve(context.root, "base")

    assert resolved.files ==
             ["lib/b.ex", "lib/keep.ex", "lib/renamed.ex", "lib/a.ex"] |> Enum.sort()

    assert resolved.base_sources["lib/a.ex"] =~ "def f, do: :f"
    refute Map.has_key?(resolved.base_sources, "lib/renamed.ex")
  end

  test "reads a path git would otherwise quote", context do
    write!(context.root, "lib/café.ex", "defmodule Café do\n  def c, do: :c\nend\n")
    git!(context.root, ["add", "lib/café.ex"])
    git!(context.root, ["commit", "-q", "-m", "accented"])
    write!(context.root, "lib/naïve.ex", "defmodule Naive do\n  def n, do: :n\nend\n")

    assert {:ok, resolved} = BaseRef.resolve(context.root, "base")
    assert "lib/café.ex" in resolved.files
    assert "lib/naïve.ex" in resolved.files
  end

  test "falls back to the ref's own commit when it shares no history with HEAD" do
    root = repository!()
    write!(root, "lib/a.ex", "defmodule A do\n  def f, do: :f\nend\n")
    git!(root, ["add", "."])
    git!(root, ["commit", "-q", "-m", "first"])
    trunk = git!(root, ["rev-parse", "--abbrev-ref", "HEAD"])

    git!(root, ["checkout", "-q", "--orphan", "unrelated"])
    write!(root, "lib/o.ex", "defmodule O do\n  def o, do: :o\nend\n")
    git!(root, ["add", "."])
    git!(root, ["commit", "-q", "-m", "unrelated"])
    orphan_sha = git!(root, ["rev-parse", "refs/heads/unrelated"])
    git!(root, ["checkout", "-q", trunk])

    assert {:ok, resolved} = BaseRef.resolve(root, "unrelated")
    assert resolved.base_sha == orphan_sha
    assert resolved.files == ["lib/o.ex"]
    assert resolved.base_sources["lib/o.ex"] =~ "def o, do: :o"
  end

  test "reports a ref no commit answers to", context do
    assert BaseRef.resolve(context.root, "nope") == {:error, "unknown ref: nope"}
  end

  test "reports a directory that is not a repository" do
    assert BaseRef.resolve(System.tmp_dir!(), "main") == {:error, "not a git repository"}
  end

  test "reports a root that does not exist" do
    missing = Path.join(System.tmp_dir!(), "grasp-missing-#{System.unique_integer([:positive])}")
    assert BaseRef.resolve(missing, "main") == {:error, "not a git repository"}
  end

  defp repository! do
    root = Path.join(System.tmp_dir!(), "grasp-base-ref-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "lib"))
    on_exit(fn -> File.rm_rf!(root) end)

    git!(root, ["-c", "init.defaultBranch=main", "init", "-q"])
    git!(root, ["config", "user.name", "Grasp Test"])
    git!(root, ["config", "user.email", "grasp@example.com"])
    git!(root, ["config", "commit.gpgsign", "false"])
    root
  end

  defp write!(root, path, contents) do
    path = Path.join(root, path)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
  end

  # Captures stdout alone, for the same reason the module under test does: a warning about
  # the ambiguous `base` ref would otherwise become part of the sha this fixture asserts on.
  defp git!(root, args) do
    {output, 0} = System.cmd("git", args, cd: root)
    String.trim(output)
  end
end
