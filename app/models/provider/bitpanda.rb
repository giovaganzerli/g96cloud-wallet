require "net/http"
require "set"

# Read-only client for the Public API, not the retiring legacy API.
class Provider::Bitpanda
  class Error < StandardError; end
  class AuthenticationError < Error; end
  class InvalidDataError < Error; end

  BASE_URL = "https://api.public.bitpanda.com/v1/".freeze
  MAX_PAGES = 10_000

  def initialize(api_key:)
    @api_key = api_key
  end

  def snapshot
    currencies = data(request("currencies"))
    euro = currencies.find { |currency| currency["symbol"] == "EUR" }
    raise InvalidDataError, "Bitpanda did not return the EUR currency" unless euro&.fetch("id", nil).present?

    {
      "currencies" => currencies,
      "assets" => paginated("assets", id_key: "id"),
      "portfolio" => data(request("portfolio", equivalent_currency_id: euro.fetch("id"))),
      "operations" => paginated("operations", id_key: "operation_id"),
      "date" => Date.current.iso8601
    }
  end

  private

    def paginated(path, id_key:)
      records = {}
      cursors = Set.new
      cursor = nil
      MAX_PAGES.times do
        response = request(path, **{ page_size: 100, cursor: cursor }.compact)
        data(response).each do |record|
          id = record[id_key]
          raise InvalidDataError, "Bitpanda #{path} record has no identifier" unless id.is_a?(String) && id.present?
          if records.key?(id) && records[id] != record
            raise InvalidDataError, "Bitpanda #{path} changed during pagination; retry synchronization"
          end
          records[id] = record
        end
        more = response["has_next_page"]
        unless [ true, false ].include?(more)
          raise InvalidDataError, "Bitpanda #{path} has no pagination status"
        end
        return records.values unless more

        cursor = response["next_cursor"]
        if cursor.blank? || !cursors.add?(cursor)
          raise InvalidDataError, "Bitpanda #{path} returned an invalid pagination cursor"
        end
      end
      raise InvalidDataError, "Bitpanda #{path} exceeded the pagination safety limit"
    end

    def data(response)
      rows = response["data"]
      unless rows.is_a?(Array) && rows.all? { |row| row.is_a?(Hash) }
        raise InvalidDataError, "Bitpanda returned an invalid data list"
      end
      rows
    end

    def request(path, **params)
      uri = URI.join(BASE_URL, path)
      uri.query = URI.encode_www_form(params) if params.any?
      request = Net::HTTP::Get.new(uri)
      request["x-api-key"] = @api_key
      request["Accept"] = "application/json"
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 60) do |http|
        http.request(request)
      end
      case response.code.to_i
      when 401, 403
        raise AuthenticationError, "Bitpanda API key is invalid or lacks Balances / Transaction permissions"
      when 429
        raise Error, "Bitpanda rate limit reached; retry synchronization later"
      when 200
        payload = JSON.parse(response.body)
        raise InvalidDataError, "Bitpanda returned an invalid response" unless payload.is_a?(Hash)
        payload
      else
        # Never include upstream bodies or request headers: they may contain secrets.
        raise Error, "Bitpanda #{path} request failed (HTTP #{response.code})"
      end
    rescue JSON::ParserError
      raise InvalidDataError, "Bitpanda returned invalid JSON"
    rescue Timeout::Error, SocketError, SystemCallError, IOError, OpenSSL::SSL::SSLError, Net::ProtocolError
      raise Error, "Bitpanda connection failed; retry synchronization later"
    end
end
