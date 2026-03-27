require "net/http"
require "json"
require "cgi"

class Api::YoutubeController < ApplicationController
  def first
    query = params[:query].to_s.strip
    return render json: { error: "missing_query" }, status: :unprocessable_entity if query.blank?

    # YouTube search HTML is not a stable API, but we only need the first video id.
    # Use the title as-is; adding extra terms can change the top result.
    search_query = query
    search_url = "https://www.youtube.com/results?search_query=#{URI.encode_www_form_component(search_query)}"

    fetch = fetch_limited_html(search_url)
    fetch_meta = fetch.is_a?(Hash) ? fetch.dup.tap { |h| h.delete(:body) } : { error: "unexpected_fetch_return", class: fetch.class.name }
    return render json: { query: query, error: "fetch_failed", fetch: fetch_meta }, status: :bad_gateway if !fetch.is_a?(Hash) || fetch[:body].nil?

    video_id = extract_first_video_id(fetch[:body])
    return render json: { query: query, error: "no_results", fetch: fetch_meta }, status: :not_found if video_id.nil?

    url = "https://www.youtube.com/watch?v=#{video_id}"
    embed_url = "https://www.youtube.com/embed/#{video_id}?autoplay=1&playsinline=1&mute=0"

    render json: { query: query, videoId: video_id, url: url, embedUrl: embed_url, fetch: fetch_meta }
  rescue Net::OpenTimeout, Net::ReadTimeout
    render json: { query: query, error: "timeout" }, status: :gateway_timeout
  rescue => e
    render json: { query: query, error: "error", message: e.message }, status: :bad_gateway
  end

  private

  def safe_http_uri(str)
    uri = URI.parse(str)
    return nil unless uri.is_a?(URI::HTTP) && uri.host.present?

    uri
  rescue URI::InvalidURIError
    nil
  end

  def fetch_limited_html(str, redirects: [], depth: 0)
    uri = safe_http_uri(str)
    return { body: nil, final_url: str, status: nil, redirects: redirects, error: "invalid_url" } if uri.nil?

    body = +""
    max_bytes = 1_000_000
    result = nil

    Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: 5, read_timeout: 10) do |http|
      req = Net::HTTP::Get.new(uri.request_uri, {
        "User-Agent" => "Hitster/1.0",
        "Accept" => "text/html",
        "Accept-Language" => "en-US,en;q=0.9"
      })

      begin
        http.request(req) do |res|
        status = res.code.to_i

        # Be explicit about OK to avoid any framework/tooling confusion.
        ok = res.is_a?(Net::HTTPOK) || res.is_a?(Net::HTTPSuccess)
        redirect = res.is_a?(Net::HTTPRedirection)

        unless ok || redirect
          result = { body: nil, final_url: uri.to_s, status: status, redirects: redirects, error: "http_error" }
          next
        end

        if redirect
          location = res["location"].to_s
          next_uri = safe_http_uri(URI.join(uri.to_s, location).to_s) rescue nil
          if next_uri.nil?
            result = { body: nil, final_url: uri.to_s, status: status, redirects: redirects, error: "bad_redirect", location: location }
            next
          end

          redirects = redirects + [{ from: uri.to_s, to: next_uri.to_s, status: status }]
          if depth >= 3
            result = { body: nil, final_url: next_uri.to_s, status: status, redirects: redirects, error: "too_many_redirects" }
            next
          end

          result = fetch_limited_html(next_uri.to_s, redirects: redirects, depth: depth + 1)
          next
        end

        res.read_body do |chunk|
          body << chunk
          break if body.bytesize > max_bytes
        end

        result = { body: body, final_url: uri.to_s, status: status, redirects: redirects }
        end
      rescue Net::HTTPBadResponse => e
        result = { body: nil, final_url: uri.to_s, status: nil, redirects: redirects, error: "bad_response", exception: e.class.name, message: e.message }
      rescue EOFError, Errno::ECONNRESET, Errno::EPIPE, IOError => e
        result = { body: nil, final_url: uri.to_s, status: nil, redirects: redirects, error: "io_error", exception: e.class.name, message: e.message }
      end
    end

    result || { body: nil, final_url: uri.to_s, status: nil, redirects: redirects, error: "no_response" }
  rescue Net::OpenTimeout, Net::ReadTimeout => e
    { body: nil, final_url: uri&.to_s || str, status: nil, redirects: redirects, error: "timeout", exception: e.class.name, message: e.message }
  rescue => e
    { body: nil, final_url: uri&.to_s || str, status: nil, redirects: redirects, error: "exception", exception: e.class.name, message: e.message }
  end

  def extract_first_video_id(html)
    # Unescape so patterns like `&amp;` don't interfere with regexes.
    html = CGI.unescapeHTML(html.to_s)

    # Prefer watch links (usually present in the initial HTML).
    match = html.match(%r{/watch\?v=([a-zA-Z0-9_-]{11})})
    return match[1] if match

    # Sometimes the HTML uses `watch?v=` without a leading slash.
    match = html.match(%r{watch\?v=([a-zA-Z0-9_-]{11})})
    return match[1] if match

    # Fallback: often present in the initial HTML/JSON blobs.
    match = html.match(/"videoId"\s*:\s*"([a-zA-Z0-9_-]{11})"/)
    match && match[1]
  end
end

