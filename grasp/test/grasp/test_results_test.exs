defmodule Grasp.TestResultsTest do
  use ExUnit.Case, async: true

  alias Grasp.TestResults

  @kept ~s(Acme.TallyTest."test keeps the count"/1)
  @rerun ~s(Acme.TallyTest."test counts up"/1)
  @sibling ~s(Acme.TallyTest."test counts down"/1)

  defp record(id, source), do: %{"id" => id, "kind" => "test", "source" => source}

  defp index(records) do
    {:ok, index} = Grasp.Index.from_document(%{"version" => 1, "functions" => records})
    index
  end

  defp meta(run_id, index),
    do: %{run_id: run_id, finished_at: "2026-09-28T12:00:00Z", index: index}

  describe "merge/3" do
    test "keeps the results of tests the run does not name and replaces the ones it does" do
      index = index([record(@kept, "kept"), record(@rerun, "rerun")])

      first =
        TestResults.merge(
          nil,
          %{
            @kept => %{"status" => "failed", "time" => 5, "errors" => []},
            @rerun => %{"status" => "failed", "time" => 6, "errors" => []}
          },
          meta("one", index)
        )

      second =
        TestResults.merge(
          first,
          %{@rerun => %{"status" => "passed", "time" => 7, "errors" => []}},
          meta("two", index)
        )

      assert second["tests"][@kept] == first["tests"][@kept]
      assert %{"status" => "failed", "run_id" => "one"} = second["tests"][@kept]

      assert second["tests"][@rerun] == %{
               "status" => "passed",
               "time" => 7,
               "errors" => [],
               "run_id" => "two",
               "finished_at" => "2026-09-28T12:00:00Z",
               "source_hash" => sha256("rerun")
             }
    end

    test "an excluded result replaces only an absent or excluded one" do
      excluded = %{"status" => "excluded", "time" => 0, "errors" => []}

      first =
        TestResults.merge(
          nil,
          %{@rerun => %{"status" => "passed", "time" => 3, "errors" => []}, @sibling => excluded},
          meta("one", nil)
        )

      second =
        TestResults.merge(first, %{@rerun => excluded, @sibling => excluded}, meta("two", nil))

      assert %{"status" => "passed", "run_id" => "one"} = second["tests"][@rerun]
      assert %{"status" => "excluded", "run_id" => "two"} = second["tests"][@sibling]
    end

    test "a test the index does not hold is stored with no source hash" do
      document =
        TestResults.merge(
          nil,
          %{@kept => %{"status" => "passed", "time" => 1, "errors" => []}},
          meta("one", index([]))
        )

      assert document["tests"][@kept]["source_hash"] == nil
    end
  end

  describe "for_test/2" do
    setup do
      document =
        TestResults.merge(
          nil,
          %{@kept => %{"status" => "failed", "time" => 5, "errors" => []}},
          meta("one", index([record(@kept, "kept")]))
        )

      %{document: document}
    end

    test "a result recorded against the record's source is fresh", %{document: document} do
      assert {:fresh, %{"status" => "failed"}} =
               TestResults.for_test(document, record(@kept, "kept"))
    end

    test "a result recorded against another source is stale", %{document: document} do
      assert {:stale, %{"status" => "failed"}} =
               TestResults.for_test(document, record(@kept, "kept, edited"))
    end

    test "a test with no result reads none", %{document: document} do
      assert TestResults.for_test(document, record(@rerun, "rerun")) == :none
    end
  end

  describe "encode/1 and decode/1" do
    test "a document reads back as written, less the results it cannot read" do
      document =
        TestResults.merge(
          nil,
          %{@kept => %{"status" => "passed", "time" => 1, "errors" => []}},
          meta("one", nil)
        )

      json =
        document
        |> put_in(["tests", @rerun], %{"status" => "exploded"})
        |> TestResults.encode()

      assert TestResults.decode(json) == {:ok, document}
    end

    test "another version is refused" do
      assert TestResults.decode(~s({"version": 2, "tests": {}})) ==
               {:error, {:unsupported_document, 2}}
    end
  end

  @tag :tmp_dir
  test "write/2 and read/1 round-trip, and a missing file reads empty", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "nested/results.json")
    assert TestResults.read(path) == {:ok, TestResults.new()}

    document =
      TestResults.merge(
        nil,
        %{@kept => %{"status" => "skipped", "time" => 0, "errors" => []}},
        meta("one", nil)
      )

    assert TestResults.write(document, path) == :ok
    assert TestResults.read(path) == {:ok, document}
    assert File.ls!(Path.dirname(path)) == ["results.json"]
  end

  defp sha256(text), do: Base.encode16(:crypto.hash(:sha256, text), case: :lower)

  describe "merge_file/3" do
    @describetag :tmp_dir

    defp run_results(prefix, count) do
      Map.new(1..count, fn n ->
        {~s(Acme.RaceTest."test #{prefix} #{n}"/1),
         %{"status" => "passed", "time" => n, "errors" => []}}
      end)
    end

    test "runs merging at once each keep the other's results", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "results.json")

      runs =
        for prefix <- ~w(a b c d e f g h) do
          Task.async(fn ->
            for round <- 1..5 do
              {:ok, _document, nil} =
                TestResults.merge_file(
                  path,
                  run_results("#{prefix}#{round}", 3),
                  meta(prefix, nil)
                )
            end
          end)
        end

      Task.await_many(runs, 60_000)

      {:ok, document} = TestResults.read(path)
      assert map_size(document["tests"]) == 8 * 5 * 3
      assert Path.wildcard(Path.join(tmp_dir, "*")) == [path]
    end

    test "a held lock is waited for, and a stale one is taken over", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "results.json")
      lock = path <> ".lock"

      File.write!(lock, "")
      parent = self()

      waiter =
        Task.async(fn ->
          send(parent, :waiting)
          TestResults.merge_file(path, run_results("held", 1), meta("held", nil))
        end)

      assert_receive :waiting
      Process.sleep(300)
      refute File.exists?(path)
      File.rm!(lock)
      assert {:ok, _document, nil} = Task.await(waiter)

      File.write!(lock, "")
      File.touch!(lock, System.os_time(:second) - 11 * 60)

      assert {:ok, document, nil} =
               TestResults.merge_file(path, run_results("stale", 1), meta("stale", nil))

      assert map_size(document["tests"]) == 2
      refute File.exists?(lock)
    end

    test "each document that does not decode is set aside under a name of its own",
         %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "results.json")

      set_asides =
        for text <- [~s({"version": 7}), "{not json"] do
          File.write!(path, text)

          assert {:ok, document, set_aside} =
                   TestResults.merge_file(path, run_results("fresh", 1), meta("one", nil))

          assert map_size(document["tests"]) == 1
          assert Path.dirname(set_aside) == tmp_dir
          assert Path.basename(set_aside) =~ ~r/^results\.json\.\d{8}T\d{6}Z-[\d-]+\.corrupt$/
          set_aside
        end

      assert Enum.map(set_asides, &File.read!/1) == [~s({"version": 7}), "{not json"]
    end
  end
end
