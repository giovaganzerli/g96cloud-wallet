require "test_helper"

class PwaControllerTest < ActionDispatch::IntegrationTest
  test "manifest responds successfully for html accept headers" do
    get "/manifest", headers: { "Accept" => "text/html" }

    assert_response :success
    assert_equal "application/manifest+json", response.media_type
    assert_includes response.body, '"start_url": "/"'
    assert_includes response.body, '"url": "/transactions/quick-new"'
  end

  test "quick-entry manifest has its own app identity and launch URL" do
    get "/quick-manifest", headers: { "Accept" => "text/html" }

    assert_response :success
    assert_equal "application/manifest+json", response.media_type

    manifest = JSON.parse(response.body)
    assert_equal "/transactions/quick-new", manifest.fetch("id")
    assert_equal "/transactions/quick-new", manifest.fetch("start_url")
    assert_equal "/transactions/quick-new", manifest.fetch("scope")
    assert_equal "fullscreen", manifest.fetch("display")
  end

  test "service worker responds successfully without origin or referer headers" do
    get "/service-worker", headers: {
      "Accept" => "*/*",
      "DNT" => "1",
      "Sec-GPC" => "1"
    }

    assert_response :success
    assert_equal "application/javascript", response.media_type
  end
end
