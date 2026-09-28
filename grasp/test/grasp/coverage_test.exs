defmodule Grasp.CoverageTest do
  use ExUnit.Case, async: true

  alias Grasp.Coverage

  @next_source """
  def next(count) when count >= 0 do
    count + 1
  end
  """

  @meta %{generated_at: "2026-09-28T12:00:00Z", git_head: "abc123"}

  defp index(records) do
    {:ok, index} =
      Grasp.Index.from_document(%{
        "version" => 1,
        "generated_at" => "2026-09-28T11:58:00Z",
        "project" => %{"test_paths" => ["test"]},
        "functions" => records
      })

    index
  end

  defp record(id, file, first, last, extra \\ %{}) do
    [name, arity] = id |> String.split(".") |> List.last() |> String.split("/")
    module = id |> String.split(".") |> Enum.drop(-1) |> Enum.join(".")

    Map.merge(
      %{
        "id" => id,
        "module" => module,
        "name" => name,
        "arity" => String.to_integer(arity),
        "arities" => [String.to_integer(arity)],
        "kind" => "def",
        "file" => file,
        "span" => %{"start_line" => first, "end_line" => last},
        "source" => "source of #{id}",
        "calls" => []
      },
      extra
    )
  end

  describe "build/3" do
    test "keeps each function's counted lines inside its span, as offsets from its start" do
      next = record("Acme.Tally.next/1", "lib/acme/tally.ex", 2, 4, %{"source" => @next_source})
      reset = record("Acme.Tally.reset/0", "lib/acme/tally.ex", 6, 8)

      document =
        Coverage.build(
          index([next, reset]),
          %{{"Acme.Tally", "next", 1} => %{1 => 9, 2 => 3, 3 => 3, 5 => 1}},
          @meta
        )

      assert document["version"] == 1
      assert document["generated_at"] == "2026-09-28T12:00:00Z"
      assert document["git_head"] == "abc123"
      assert document["index_generated_at"] == "2026-09-28T11:58:00Z"

      assert document["functions"] == %{
               "Acme.Tally.next/1" => %{
                 "source_hash" =>
                   Base.encode16(:crypto.hash(:sha256, @next_source), case: :lower),
                 "lines" => %{"0" => 3, "1" => 3}
               }
             }
    end

    test "credits a record only with the counts of its own module, name and arities" do
      greet =
        record("Acme.Greeter.greet/2", "lib/acme/greeter.ex", 3, 6, %{"arities" => [1, 2]})

      document =
        Coverage.build(
          index([greet]),
          %{
            {"Acme.Greeter", "greet", 1} => %{3 => 1},
            {"Acme.Greeter", "greet", 2} => %{3 => 2, 4 => 2},
            {"Acme.Greeter", "wave", 1} => %{5 => 7},
            {"Acme.Other", "greet", 2} => %{6 => 7}
          },
          @meta
        )

      assert document["functions"]["Acme.Greeter.greet/2"]["lines"] == %{"0" => 3, "1" => 2}
    end

    test "leaves out tests, setups, macros, guards, test-path files and removed functions" do
      lines = %{2 => 1, 3 => 0}

      records = [
        record("Acme.TallyTest.next_test/1", "test/acme/tally_test.exs", 2, 3, %{
          "kind" => "test"
        }),
        record("Acme.TallyTest.setup_0/1", "lib/acme/setup.ex", 2, 3, %{"kind" => "setup"}),
        record("Acme.Macros.twice/1", "lib/acme/macros.ex", 2, 3, %{"kind" => "defmacro"}),
        record("Acme.Macros.thrice/1", "lib/acme/macros.ex", 2, 3, %{"kind" => "defmacrop"}),
        record("Acme.Macros.small/1", "lib/acme/macros.ex", 2, 3, %{"kind" => "defguard"}),
        record("Acme.Support.build/1", "test/support/build.ex", 2, 3),
        record("Acme.Tally.gone/1", "lib/acme/tally.ex", 2, 3, %{"removed" => true})
      ]

      counts =
        Map.new(records, fn record ->
          {{record["module"], record["name"], record["arity"]}, lines}
        end)

      assert Coverage.build(index(records), counts, @meta)["functions"] == %{}
    end
  end

  describe "decode/1" do
    test "reads back what encode/1 wrote" do
      document =
        Coverage.build(
          index([record("Acme.Tally.next/1", "lib/acme/tally.ex", 2, 4)]),
          %{{"Acme.Tally", "next", 1} => %{2 => 1}},
          @meta
        )

      assert {:ok, ^document} = document |> Coverage.encode() |> Coverage.decode()
    end

    test "rejects what is not a coverage document" do
      assert Coverage.decode(~s({"version": 2, "functions": {}})) ==
               {:error, {:unsupported_document, 2}}

      assert Coverage.decode("[]") == {:error, {:unsupported_document, nil}}
      assert {:error, %Jason.DecodeError{}} = Coverage.decode("{")
    end
  end

  describe "write/2" do
    @tag :tmp_dir
    test "writes the document where it is asked, creating the directory", %{tmp_dir: tmp_dir} do
      path = Path.join([tmp_dir, ".grasp", "coverage.json"])
      document = Coverage.build(index([]), %{}, @meta)

      assert Coverage.write(document, path) == :ok
      assert Coverage.decode(File.read!(path)) == {:ok, document}
      refute File.exists?(path <> ".tmp")
    end
  end

  describe "for_function/2" do
    setup do
      record = record("Acme.Tally.next/1", "lib/acme/tally.ex", 2, 4)

      {:ok, coverage} =
        index([record])
        |> Coverage.build(%{{"Acme.Tally", "next", 1} => %{2 => 4, 3 => 0}}, @meta)
        |> Coverage.encode()
        |> Coverage.decode()

      %{record: record, coverage: coverage}
    end

    test "is fresh while the source is the one the coverage is written against",
         %{record: record, coverage: coverage} do
      assert Coverage.for_function(coverage, record) == {:fresh, %{lines: %{2 => 4, 3 => 0}}}
    end

    test "stays fresh on the lines a function moved to with its source unchanged",
         %{record: record, coverage: coverage} do
      moved = %{record | "span" => %{"start_line" => 5, "end_line" => 7}}
      assert Coverage.for_function(coverage, moved) == {:fresh, %{lines: %{5 => 4, 6 => 0}}}
    end

    test "is stale once the source differs", %{record: record, coverage: coverage} do
      assert {:stale, %{"lines" => %{"0" => 4}}} =
               Coverage.for_function(coverage, %{record | "source" => "def next(c), do: c"})
    end

    test "is none for a function the coverage holds nothing for", %{coverage: coverage} do
      other = record("Acme.Tally.reset/0", "lib/acme/tally.ex", 6, 8)
      assert Coverage.for_function(coverage, other) == :none
    end

    test "is none for an entry it cannot read", %{record: record} do
      coverage = %{"functions" => %{record["id"] => %{"lines" => %{"0" => 1}}}}
      assert Coverage.for_function(coverage, record) == :none
    end
  end

  describe "gaps/2" do
    test "names a clause whose every counted line ran zero times" do
      record = %{"clauses" => [[2, 4], [6, 8]], "arms" => []}

      assert Coverage.gaps(record, %{2 => 3, 3 => 3, 6 => 0, 7 => 0}) ==
               %{clauses: [[6, 8]], arms: []}
    end

    test "names an arm never entered, and not an arm with no counted line" do
      record = %{"clauses" => [[10, 16]], "arms" => [[12, 12], [13, 13], [14, 15]]}

      assert Coverage.gaps(record, %{10 => 2, 11 => 2, 12 => 2, 13 => 0}) ==
               %{clauses: [], arms: [[13, 13]]}
    end

    test "names every arm never entered, an arm inside a clause never entered too" do
      record = %{"clauses" => [[2, 4], [6, 12]], "arms" => [[8, 9], [10, 11]]}

      assert Coverage.gaps(record, %{3 => 1, 7 => 0, 8 => 0, 10 => 0}) ==
               %{clauses: [[6, 12]], arms: [[8, 9], [10, 11]]}
    end

    test "answers no gaps for a function that ran all the way through" do
      record = %{"clauses" => [[2, 4]], "arms" => [[3, 3]]}
      assert Coverage.gaps(record, %{2 => 1, 3 => 1}) == %{clauses: [], arms: []}
    end
  end
end
