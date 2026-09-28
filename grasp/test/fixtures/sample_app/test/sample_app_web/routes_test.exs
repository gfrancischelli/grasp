defmodule SampleAppWeb.RoutesTest do
  use SampleApp.SampleCase, async: true
  use Phoenix.VerifiedRoutes, endpoint: SampleAppWeb.Endpoint, router: SampleAppWeb.Router

  test "a plain path reaches the controller", %{conn: conn} do
    assert get(conn, "/again").status in 200..599
  end

  test "a verified path reaches the controller", %{conn: conn} do
    assert post(conn, ~p"/greet", %{"name" => "Ada"}).status in 200..599
  end
end
