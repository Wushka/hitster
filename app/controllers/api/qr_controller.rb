require "net/http"
require "json"
require "cgi"

class Api::QrController < ApplicationController
  def title
    url = params[:url].to_s
    uri = safe_http_uri(url)
    return render json: {error: "invalid_url"}, status: :unprocessable_entity if uri.nil?

    html = fetch_limited_html(uri)
    return render json: {url: url, title: nil, error: "fetch_failed"}, status: :bad_gateway if html.nil?

    title = extract_title(html)
    render json: {url: url, title: title}
  end

  def query
    title = params[:title].to_s.strip
    return render json: {error: "missing_title"}, status: :unprocessable_entity if title.blank?

    template = ENV["HITSTER_OTHER_API_URL_TEMPLATE"].to_s
    base_url = ENV["HITSTER_OTHER_API_BASE_URL"].to_s

    target =
      if template.present?
        template.gsub("{{query}}", ERB::Util.url_encode(title))
      elsif base_url.present?
        "#{base_url}#{base_url.include?("?") ? "&" : "?"}q=#{ERB::Util.url_encode(title)}"
      end

    return render json: {error: "other_api_not_configured"}, status: :not_implemented if target.nil?

    uri = safe_http_uri(target)
    return render json: {error: "invalid_other_api_url"}, status: :unprocessable_entity if uri.nil?

    response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: 5, read_timeout: 10) do |http|
      http.get(uri.request_uri, {"Accept" => "application/json"})
    end

    render json: {
      requested_title: title,
      other_api_url: target,
      status: response.code.to_i,
      headers: response.to_hash.transform_values { |v| Array(v).join(", ") },
      body: safe_parse_json(response.body)
    }
  rescue Net::OpenTimeout, Net::ReadTimeout
    render json: {error: "other_api_timeout"}, status: :gateway_timeout
  rescue => e
    render json: {error: "other_api_error", message: e.message}, status: :bad_gateway
  end

  private

  def safe_http_uri(str)
    uri = URI.parse(str)
    return nil unless uri.is_a?(URI::HTTP) && uri.host.present?

    uri
  rescue URI::InvalidURIError
    nil
  end

  def fetch_limited_html(uri)
    body = +""

    Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: 5, read_timeout: 10) do |http|
      req = Net::HTTP::Get.new(uri.request_uri, {"User-Agent" => "Hitster/1.0", "Accept" => "text/html,application/xhtml+xml"})
      http.request(req) do |res|
        return nil unless res.is_a?(Net::HTTPSuccess) || res.is_a?(Net::HTTPRedirection)

        if res.is_a?(Net::HTTPRedirection)
          location = res["location"].to_s
          next_uri = begin
            safe_http_uri(URI.join(uri.to_s, location).to_s)
          rescue
            nil
          end
          return nil if next_uri.nil?
          return fetch_limited_html(next_uri)
        end

        res.read_body do |chunk|
          body << chunk
          break if body.bytesize > 200_000
        end
      end
    end

    body
  rescue Net::OpenTimeout, Net::ReadTimeout
    nil
  rescue
    nil
  end

  def extract_title(html)
    match = html.match(/<title[^>]*>(.*?)<\/title>/im)
    return nil if match.nil?

    title = match[1].to_s
    # Convert HTML entities like `&amp;` and numeric entities into real characters.
    title = CGI.unescapeHTML(title)
    # If the title has embedded tags, strip them (rare, but makes output safer).
    title = title.gsub(/<[^>]+>/, " ")
    # Normalize non-breaking spaces and whitespace.
    title = title.tr("\u00A0", " ")
    title = title.gsub(/\s+/, " ").strip
    title.presence
  end

  def safe_parse_json(body)
    JSON.parse(body)
  rescue JSON::ParserError
    body.to_s
  end
end
