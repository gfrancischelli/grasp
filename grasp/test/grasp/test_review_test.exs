defmodule Grasp.TestReviewTest do
  use ExUnit.Case, async: true

  alias Grasp.TestReview

  describe "assertions/1" do
    test "collapses each assertion's whitespace and reads the op and left of a comparison" do
      source = """
        test "x" do
          assert   total(cart) ==
                     42
          refute_receive {:done, _}
          conn
          |> get("/x")
          |> assert_element("a")
          assert ok?
        end
      """

      assert TestReview.assertions(source) == [
               %{name: "assert", text: "assert total(cart) == 42", op: :==, left: "total(cart)"},
               %{name: "refute_receive", text: "refute_receive {:done, _}"},
               %{name: "assert_element", text: ~s[conn |> get("/x") |> assert_element("a")]},
               %{name: "assert", text: "assert ok?"}
             ]
    end

    test "is empty for a source that does not parse" do
      assert TestReview.assertions(~s|test "x" do\n  assert (|) == []
    end
  end

  describe "review/1" do
    test "a modified test that lost an assertion is weakened, naming it" do
      assert TestReview.review(
               modified(
                 "assert a == 1\n    assert  b ==  2",
                 "assert a == 1"
               )
             ) == {:weakened, ["removed: assert b == 2"]}
    end

    test "an assertion made fewer times than at the base is removed" do
      assert TestReview.review(modified("assert a\n    assert a", "assert a")) ==
               {:weakened, ["removed: assert a"]}
    end

    test "an assert_ or refute_ call made fewer times is dropped" do
      base = "assert_receive :one\n    assert_receive :two\n    refute_received :three"
      head = "assert_receive :one\n    assert :two in seen"

      assert TestReview.review(modified(base, head)) ==
               {:weakened,
                [
                  "removed: assert_receive :two",
                  "removed: refute_received :three",
                  "dropped: assert_receive",
                  "dropped: refute_received"
                ]}
    end

    test "an equality turned into a match, a membership or a bare truth is loosened" do
      for head <- [
            ~s|assert name(user) =~ "Ada"|,
            ~s|assert name(user) in ["Ada", "Bob"]|,
            ~s|assert match?("Ad" <> _, name(user))|,
            ~s|assert name(user)|
          ] do
        assert TestReview.review(modified(~s|assert name(user) == "Ada"|, head)) ==
                 {:weakened, [~s|loosened: assert name(user) == "Ada"|]}
      end

      assert TestReview.review(modified(~s|assert name(user) === "Ada"|, ~s|assert name(user)|)) ==
               {:weakened, [~s|loosened: assert name(user) === "Ada"|]}
    end

    test "a loosened equality made twice at the base is one reason" do
      assert TestReview.review(modified("assert a == 1\n    assert a == 1", "assert a")) ==
               {:weakened, ["removed: assert a == 1", "loosened: assert a == 1"]}
    end

    test "only an equality loosens" do
      assert TestReview.review(modified("assert a != 1", "assert a")) == :ok
    end

    test "an equality loosens only into an assertion on the same left side" do
      assert TestReview.review(modified("assert a == 1", ~s|assert b =~ "1"|)) == :ok
    end

    test "an edit that keeps the number of assertions is not a weakening" do
      assert TestReview.review(modified("assert a == 1", "assert a == 2")) == :ok

      assert TestReview.review(modified("assert_receive :x, 100", "assert_receive :x, 500")) ==
               :ok

      assert TestReview.review(modified("refute a == 1", "refute a")) == :ok
    end

    test "splitting one assertion into two is not a weakening" do
      base = "assert a == 1 and b == 2"
      assert TestReview.review(modified(base, "assert a == 1\n    assert b == 2")) == :ok
    end

    test "compares assertions by their parsed form, so the formatter's rewrap is the same one" do
      long =
        "assert %{status: :ok, total: 4200, currency: \"EUR\", lines: [1, 2, 3], " <>
          "customer: \"Ada Lovelace\", note: \"gift\"} = Checkout.run(cart)"

      head = "x" |> body(long) |> Code.format_string!() |> IO.iodata_to_binary()
      assert head =~ "%{\n"

      record =
        "x"
        |> record(long)
        |> Map.merge(%{
          "change" => "modified",
          "source" => head,
          "base_source" => body("x", long <> "\n    assert extra")
        })

      assert TestReview.review(record) == {:weakened, ["removed: assert extra"]}
    end

    test "a changed string inside an assertion is a different assertion" do
      assert TestReview.review(
               modified(~s|assert s == "a  b"\n    assert t|, ~s|assert s == "a b"|)
             ) ==
               {:weakened, [~s|removed: assert s == "a b"|, "removed: assert t"]}
    end

    test "a test that reorders or rewraps its assertions is not marked" do
      base = "assert a == 1\n    assert_receive :done\n    refute b"
      head = "refute b\n    assert_receive :done\n    assert a ==\n             1"

      assert TestReview.review(modified(base, head)) == :ok
    end

    test "an equality the head still makes is not loosened by a looser companion" do
      assert TestReview.review(modified("assert a == 1", "assert a == 1\n    assert a")) == :ok
    end

    test "an added test with no assertion asserts nothing" do
      assert TestReview.review(added(":ok")) == :asserts_nothing
      assert TestReview.review(added("assert :ok")) == :ok
    end

    test "a source that does not parse is not marked" do
      assert TestReview.review(modified("assert a == 1", "assert (")) == :ok
      assert TestReview.review(modified("assert (", ":ok")) == :ok
      assert TestReview.review(added("assert (")) == :ok
    end

    test "a test the branch left alone, and a function, are not marked" do
      assert TestReview.review(%{added(":ok") | "change" => "unchanged"}) == :ok
      assert TestReview.review(%{added(":ok") | "kind" => "def"}) == :ok
    end
  end

  defp modified(base, head) do
    %{record("x", head) | "change" => "modified"} |> Map.put("base_source", body("x", base))
  end

  defp added(body), do: %{record("x", body) | "change" => "added"}

  defp record(name, body) do
    %{
      "id" => ~s|M."test #{name}"/1|,
      "kind" => "test",
      "change" => nil,
      "source" => body(name, body)
    }
  end

  defp body(name, body), do: ~s|  test "#{name}" do\n    #{body}\n  end|
end
