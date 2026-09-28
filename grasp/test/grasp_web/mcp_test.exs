defmodule GraspWeb.MCPTest do
  use GraspWeb.ConnCase, async: true

  @greet "SampleApp.Greeter.greet/2"
  @wrap "SampleApp.Formatter.wrap/1"
  @show "SampleAppWeb.GreetController.show/2"

  test "initialize, list tools, call one", %{conn: conn} do
    {conn, session} = initialize(conn)

    result = rpc(conn, session, "tools/list", %{})
    names = result["tools"] |> Enum.map(& &1["name"]) |> Enum.sort()

    assert names ==
             ~w(add_comment close_card coverage find_paths focus_card get_callees get_callers
                get_function get_session group_cards highlight_card list_changes list_comments
                list_entry_points list_modules list_sessions open_card publish_comments
                reload_index rename_group reply_comment resolve_comment run_coverage
                run_status run_tests search_functions set_cards set_view tests_for
                ungroup_cards untested_changes)

    assert Enum.all?(result["tools"], &(&1["description"] not in [nil, ""]))

    result =
      rpc(conn, session, "tools/call", %{
        "name" => "get_callees",
        "arguments" => %{"id" => @greet}
      })

    assert [%{"type" => "text", "text" => text}] = result["content"]
    assert %{"callees" => callees} = Jason.decode!(text)
    assert "SampleApp.Formatter.wrap/1" in callees
  end

  @tag capture_log: true
  test "tests_for and untested_changes answer over the endpoint", %{conn: conn} do
    {conn, session} = initialize(conn)

    result =
      rpc(conn, session, "tools/call", %{
        "name" => "tests_for",
        "arguments" => %{"function_id" => "SampleApp.Counter.init/1"}
      })

    refute result["isError"]
    assert [%{"type" => "text", "text" => text}] = result["content"]

    assert %{"id" => "SampleApp.Counter.init/1", "tests" => [%{"hops" => 2}]} =
             Jason.decode!(text)

    conn =
      post_json(conn, session, %{
        "jsonrpc" => "2.0",
        "id" => System.unique_integer([:positive]),
        "method" => "tools/call",
        "params" => %{
          "name" => "tests_for",
          "arguments" => %{"function_id" => "SampleApp.Counter.init/1", "max_hops" => 9}
        }
      })

    assert %{"error" => %{"message" => "Invalid params"}} = decode(conn)

    result = rpc(conn, session, "tools/call", %{"name" => "untested_changes", "arguments" => %{}})

    refute result["isError"]
    assert [%{"type" => "text", "text" => text}] = result["content"]
    assert %{"functions" => [_ | _]} = Jason.decode!(text)
  end

  test "cards set over MCP are what the review page renders", %{conn: conn} do
    {conn, session} = initialize(conn)
    name = "http-#{System.unique_integer([:positive])}"

    {:ok, view, _html} = live(%{Phoenix.ConnTest.build_conn() | host: "127.0.0.1"}, "/s/#{name}")

    result =
      rpc(conn, session, "tools/call", %{
        "name" => "set_cards",
        "arguments" => %{
          "session" => name,
          "cards" => [
            %{"key" => "a", "function_id" => @show},
            %{
              "key" => "b",
              "function_id" => "SampleApp.Greeter.greet/1",
              "parent_key" => "a",
              "highlight" => %{"call" => @wrap}
            }
          ]
        }
      })

    refute result["isError"]

    # The view was already connected when the call landed, so this is the broadcast
    # reaching a tab the user is looking at, not a fresh mount reading the session.
    assert render(view) =~ "data-function-id=\"#{@show}\""
    assert has_element?(view, "#card-1[data-function-id='#{@show}']")
    assert has_element?(view, "#card-2[data-function-id='#{@greet}']")
    assert has_element?(view, "#card-2 .call[data-highlight='true'][data-target='#{@wrap}']")

    result =
      rpc(conn, session, "tools/call", %{
        "name" => "highlight_card",
        "arguments" => %{"session" => name, "card_id" => 2, "highlight" => %{}}
      })

    refute result["isError"]
    assert [%{"text" => text}] = result["content"]
    assert %{"cards" => cards} = Jason.decode!(text)
    assert Enum.find(cards, &(&1["id"] == 2))["highlight"] == nil
  end

  test "a request addressed to another host is refused", %{conn: conn} do
    conn =
      %{conn | host: "evil.example"}
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json, text/event-stream")
      |> post("/mcp", Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"}))

    assert conn.status == 403
    assert conn.resp_body == "forbidden"
  end

  test "a loopback request a foreign page declares an origin for is refused", %{conn: conn} do
    conn =
      %{conn | host: "127.0.0.1"}
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json, text/event-stream")
      |> put_req_header("origin", "http://evil.example")
      |> post("/mcp", Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"}))

    assert conn.status == 403
    assert conn.resp_body == "forbidden"
  end

  test "host and origin checks ignore case, and a refusal is plain text", %{conn: conn} do
    conn =
      %{conn | host: "LOCALHOST"}
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json, text/event-stream")
      |> put_req_header("origin", "http://LocalHost:4040")
      |> post("/mcp", Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"}))

    refute conn.status == 403

    conn =
      %{Phoenix.ConnTest.build_conn() | host: "evil.example"}
      |> put_req_header("content-type", "application/json")
      |> post("/mcp", "{}")

    assert conn.status == 403
    assert ["text/plain" <> _] = get_resp_header(conn, "content-type")
  end

  test "the review page is guarded the same way", %{conn: conn} do
    assert %{conn | host: "evil.example"} |> get("/") |> response(403) == "forbidden"
    assert conn |> get("/") |> html_response(200)
  end

  # -- helpers -------------------------------------------------------------

  defp initialize(conn) do
    conn =
      post_json(conn, nil, %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => "2025-06-18",
          "capabilities" => %{},
          "clientInfo" => %{"name" => "test", "version" => "0"}
        }
      })

    assert %{"result" => %{"serverInfo" => %{"name" => "grasp"}}} = decode(conn)
    [session] = get_resp_header(conn, "mcp-session-id")

    post_json(Phoenix.ConnTest.build_conn(), session, %{
      "jsonrpc" => "2.0",
      "method" => "notifications/initialized"
    })

    {%{Phoenix.ConnTest.build_conn() | host: "127.0.0.1"}, session}
  end

  defp rpc(conn, session, method, params) do
    conn =
      post_json(conn, session, %{
        "jsonrpc" => "2.0",
        "id" => System.unique_integer([:positive]),
        "method" => method,
        "params" => params
      })

    assert %{"result" => result} = decode(conn)
    result
  end

  defp post_json(conn, session, body) do
    %{recycle(conn) | host: "127.0.0.1"}
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", "application/json, text/event-stream")
    |> then(&if(session, do: put_req_header(&1, "mcp-session-id", session), else: &1))
    |> post("/mcp", Jason.encode!(body))
  end

  # The transport answers a POST either as one JSON document or as an SSE stream holding it.
  defp decode(conn) do
    case Plug.Conn.get_resp_header(conn, "content-type") do
      ["text/event-stream" <> _] ->
        conn.resp_body
        |> String.split("\n")
        |> Enum.filter(&String.starts_with?(&1, "data:"))
        |> Enum.map(&(&1 |> String.trim_leading("data:") |> String.trim() |> Jason.decode!()))
        |> List.last()

      _ ->
        Jason.decode!(conn.resp_body)
    end
  end
end
