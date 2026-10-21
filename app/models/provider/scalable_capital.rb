require "open3"
require "timeout"

# Uses the official CLI's versioned JSON interface, never private browser APIs.
# Login is operator-driven; no password or token is accepted by the web app.
class Provider::ScalableCapital
  class Error < StandardError; end
  class AuthenticationError < Error; end
  class ConfigurationError < Error; end
  class InvalidDataError < Error; end

  MAX_PAGES = 1_000
  COMMAND_TIMEOUT = 90
  MAX_OUTPUT_BYTES = 16.megabytes

  # Official CLI error codes that mean "the operator must authorize again"
  # and "the local setup is wrong", kept apart so the app asks for the right
  # action instead of a generic failure.
  AUTHENTICATION_CODES = %w[no_session refresh_relogin_required auth_grant_not_enabled].freeze
  CONFIGURATION_CODES = %w[secret_storage_unavailable device_locked].freeze

  # Only these summary types need a per-transaction detail call. Cash
  # movements carry everything the ledger needs in the summary, and a detail
  # call per cash movement would multiply CLI invocations by the size of the
  # history without adding information.
  DETAIL_REQUIRED_TYPES = %w[
    BrokerSecurityTransactionSummary
    BrokerNonTradeSecurityTransactionSummary
    BrokerEltifTransactionSummary
  ].freeze

  def self.executable
    ENV.fetch("SCALABLE_CAPITAL_CLI_PATH", "/usr/local/bin/sc")
  end

  def self.available?
    Pathname.new(executable).absolute? && File.executable?(executable)
  end

  def initialize(item)
    @item = item
  end

  def session_directory
    Rails.root.join("storage", "scalable_capital", @item.family_id, @item.id)
  end

  def prepare_session!
    raise ConfigurationError, "Scalable CLI is not installed" unless self.class.available?

    FileUtils.mkdir_p(config_directory, mode: 0o700)
    [ session_directory, session_directory.join(".config"), config_directory ].each do |dir|
      File.chmod(0o700, dir)
    end
    config = config_directory.join("config.toml")
    File.write(config, "[auth]\nsession_backend = \"file\"\nsigning_key_backend = \"file\"\n", mode: "w", perm: 0o600)
  end

  def login!
    prepare_session!
    with_session_lock do
      # system with separate arguments deliberately avoids a shell. Keep the
      # lock in this parent process while the human completes OAuth and 2FA.
      system(session_environment, self.class.executable, "login", "--local-read-only") ||
        raise(AuthenticationError, "Scalable Capital login did not complete")
    end
  end

  def logout!
    with_session_lock { read_command("logout") }
  end

  def snapshot(portfolio_id: nil)
    with_session_lock do
      options = portfolio_id.present? ? [ "--portfolio-id", portfolio_id ] : []
      overview = read_command("broker", "overview", *options)
      # Pin all following reads to the resolved portfolio, not mutable CLI context.
      options = [ "--portfolio-id", required_id(overview, "portfolio_id") ]
      holdings = read_command("broker", "holdings", *options)
      unless holdings["items"].is_a?(Array) && holdings["count"] == holdings["items"].size
        raise InvalidDataError, "Scalable Capital returned an incomplete holdings list"
      end
      cash = read_command("broker", "cash-breakdown", *options)
      pages = transactions(options)
      details = details_for(pages, options)

      [ holdings, cash, *details.values ].each do |response|
        unless response["portfolio_id"] == overview["portfolio_id"] && response["account_id"] == overview["account_id"]
          raise InvalidDataError, "Scalable Capital returned mismatched account data"
        end
      end

      {
        "overview" => overview,
        "holdings" => holdings.fetch("items"),
        "cash" => cash,
        "transactions" => pages.map { |summary| summary.merge("details" => details[summary["id"]]) },
        "date" => Date.current.iso8601
      }
    end
  rescue KeyError, TypeError
    raise InvalidDataError, "Scalable Capital returned an incomplete snapshot"
  end

  private

    def required_id(data, key)
      value = data.fetch(key)
      raise InvalidDataError, "Scalable Capital returned a missing identifier" unless value.is_a?(String) && value.present?
      value
    end

    def transactions(options)
      result = []
      cursors = Set.new
      expected_total = nil
      cursor = nil
      MAX_PAGES.times do
        args = [ "broker", "transactions", *options, "--page-size", "100" ]
        args += [ "--cursor", cursor ] if cursor
        page = read_command(*args)
        expected_total ||= page["total"]
        rows = page.fetch("items")
        raise InvalidDataError, "Scalable Capital returned invalid transactions" unless rows.is_a?(Array)
        result.concat(rows)
        cursor = page["cursor"].presence
        if cursor.nil?
          if expected_total.is_a?(Integer) && expected_total != result.size
            raise InvalidDataError, "Scalable Capital returned an incomplete transaction history"
          end
          ids = result.map { |row| required_id(row, "id") }
          raise InvalidDataError, "Scalable Capital returned duplicate transactions" unless ids.uniq.size == ids.size
          return result
        end
        raise InvalidDataError, "Scalable Capital pagination did not advance" if rows.empty? || !cursors.add?(cursor)
      end
      # Never turn a truncated history into a successful import.
      raise InvalidDataError, "Scalable Capital transaction history exceeded the page limit"
    end

    def details_for(pages, options)
      pages.each_with_object({}) do |summary, details|
        next unless DETAIL_REQUIRED_TYPES.include?(summary["summary_type"])

        id = required_id(summary, "id")
        details[id] = read_command("broker", "transaction", "details", *options, "--transaction-id", id)
      end
    end

    def session_environment
      # Official release builds ignore SC_CONFIG_DIR (it is test/debug-only).
      # HOME + XDG isolate release binaries on both Linux and macOS. Set the
      # debug override to the same location for self-built development CLIs.
      {
        "HOME" => session_directory.to_s,
        "XDG_CONFIG_HOME" => session_directory.join(".config").to_s,
        "SC_CONFIG_DIR" => config_directory.to_s
      }
    end

    def config_directory
      session_directory.join(".config", "scalable-cli")
    end

    def with_session_lock
      raise AuthenticationError, "Authorize Scalable Capital on the server first" unless session_directory.directory?

      File.open(session_directory.join("wallet.lock"), File::RDWR | File::CREAT, 0o600) do |file|
        raise Error, "Scalable Capital session is busy; retry after login or synchronization" unless file.flock(File::LOCK_EX | File::LOCK_NB)
        yield
      ensure
        file.flock(File::LOCK_UN)
      end
    end

    # Private and only called above with literal read-only command names. User
    # values are option arguments, never executable names or shell fragments.
    def read_command(*args)
      raise ConfigurationError, "Scalable CLI is not installed" unless self.class.available?

      output, status = capture(*args, "--json")
      envelope = JSON.parse(output)
      raise InvalidDataError, "Scalable Capital returned an invalid envelope" unless envelope.is_a?(Hash)
      unless status.success? && envelope["ok"] == true
        code = envelope.dig("error", "code").to_s
        raise AuthenticationError, "Scalable Capital requires a new authorization on the server" if AUTHENTICATION_CODES.include?(code)
        raise ConfigurationError, "Scalable Capital CLI setup is incomplete" if CONFIGURATION_CODES.include?(code)
        # Do not persist stdout/stderr or upstream messages: they may contain PII.
        raise Error, "Scalable Capital command failed"
      end
      data = envelope.fetch("data")
      raise InvalidDataError, "Scalable Capital returned an invalid response" unless data.is_a?(Hash)
      data
    rescue JSON::ParserError, KeyError, TypeError
      raise InvalidDataError, "Scalable Capital returned invalid JSON data"
    end

    def capture(*args)
      output = +""
      status = nil
      Open3.popen3(session_environment, self.class.executable, *args, pgroup: true) do |stdin, stdout, stderr, process|
        stdin.close
        begin
          Timeout.timeout(COMMAND_TIMEOUT) do
            streams = [ stdout, stderr ]
            total_bytes = 0
            until streams.empty?
              IO.select(streams).first.each do |stream|
                chunk = stream.read_nonblock(16_384, exception: false)
                if chunk.nil?
                  streams.delete(stream)
                elsif chunk != :wait_readable
                  total_bytes += chunk.bytesize
                  raise InvalidDataError, "Scalable Capital response is too large" if total_bytes > MAX_OUTPUT_BYTES
                  output << chunk if stream == stdout
                end
              end
            end
            status = process.value
          end
        rescue Timeout::Error
          raise Error, "Scalable Capital request timed out"
        ensure
          unless process.join(0)
            Process.kill("KILL", -process.pid) rescue Errno::ESRCH
            process.join
          end
        end
      end
      [ output, status ]
    rescue Errno::ENOENT, Errno::EACCES
      raise ConfigurationError, "Scalable CLI cannot be executed"
    end
end
