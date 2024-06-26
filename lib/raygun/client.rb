module Raygun
  # client for the Raygun REST APIv1
  # as per https://raygun.com/documentation/product-guides/crash-reporting/api/
  class Client

    ENV_IP_ADDRESS_KEYS = %w(action_dispatch.remote_ip raygun.remote_ip REMOTE_ADDR)
    NO_API_KEY_MESSAGE  = "[RAYGUN] Just a note, you've got no API Key configured, which means we can't report exceptions. Specify your Raygun API key using Raygun#setup (find yours at https://app.raygun.com)"
    MAX_BREADCRUMBS_SIZE = 100_000

    include HTTParty

    def initialize
      @api_key = require_api_key
      @headers = {
        "X-ApiKey" => @api_key
      }

      enable_http_proxy if Raygun.configuration.proxy_settings[:address]
      self.class.base_uri Raygun.configuration.api_url
      self.class.default_timeout(Raygun.configuration.error_report_send_timeout)
    end

    def require_api_key
      Raygun.configuration.api_key || print_api_key_warning
    end

    def track_exception(exception_instance, env = {}, user = nil)
      create_entry(build_payload_hash(exception_instance, env, user))
    end

    private

      def enable_http_proxy
        self.class.http_proxy(Raygun.configuration.proxy_settings[:address],
                              Raygun.configuration.proxy_settings[:port] || "80",
                              Raygun.configuration.proxy_settings[:username],
                              Raygun.configuration.proxy_settings[:password])
      end

      def client_details
        {
          name:      Raygun::CLIENT_NAME,
          version:   Raygun::VERSION,
          clientUrl: Raygun::CLIENT_URL
        }
      end

      def error_details(exception)
        details = {
          className:  exception.class.to_s,
          message:    exception.message.to_s.encode('UTF-16', :undef => :replace, :invalid => :replace).encode('UTF-8'),
          stackTrace: (exception.backtrace || []).map { |line| stack_trace_for(line) },
        }

        details.update(innerError: error_details(exception.cause)) if exception.respond_to?(:cause) && exception.cause

        details
      end

      def stack_trace_for(line)
        # see http://www.ruby-doc.org/core-2.0/Exception.html#method-i-backtrace
        file_name, line_number, method = line.split(":")
        {
          lineNumber: line_number,
          fileName:   file_name,
          methodName: method ? method.gsub(/^in `(.*?)'$/, "\\1") : "(none)"
        }
      end

      def hostname
        Socket.gethostname
      end

      def version
        Raygun.configuration.version
      end

      def user_information(env)
        env["raygun.affected_user"]
      end

      def affected_user_present?(env)
        !!env["raygun.affected_user"]
      end

      def rack_env
        ENV["RACK_ENV"]
      end

      def rails_env
        ENV["RAILS_ENV"]
      end

      def request_information(env)
        Raygun.log('retrieving request information')

        return {} if env.nil? || env.empty?
        {
          hostName:    env["SERVER_NAME"],
          url:         env["PATH_INFO"],
          httpMethod:  env["REQUEST_METHOD"],
          iPAddress:   "#{ip_address_from(env)}",
          queryString: Rack::Utils.parse_nested_query(env["QUERY_STRING"]),
          headers:     headers(env),
          form:        form_params(env),
          rawData:     raw_data(env)
        }
      end

      def headers(rack_env)
        rack_env.select { |k, v| k.to_s.start_with?("HTTP_") }.inject({}) do |hsh, (k, v)|
          hsh[normalize_raygun_header_key(k)] = v
          hsh
        end
      end

      def normalize_raygun_header_key(key)
        key.sub(/^HTTP_/, '')
           .sub(/_/, ' ')
           .split.map(&:capitalize).join(' ')
           .sub(/ /, '-')
      end

      def form_params(env)
        Raygun.log('retrieving form params')

        params = action_dispatch_params(env) || rack_params(env) || {}
        filter_params_with_blacklist(params, env["action_dispatch.parameter_filter"])
      end

      def action_dispatch_params(env)
        env["action_dispatch.request.parameters"]
      end

      def rack_params(env)
        request = Rack::Request.new(env)
        request.params if env["rack.input"]
      end

      def raw_data(rack_env)
        Raygun.log('retrieving raw data')
        request = Rack::Request.new(rack_env)

        return unless Raygun.configuration.record_raw_data
        return if request.get?
        Raygun.log('passed raw_data checks')

        input = rack_env['rack.input']

        if input && !request.form_data?
          input.rewind

          body = input.read(4096) || ''
          input.rewind

          body
        else
          {}
        end
      end

      def filter_custom_data(env)
        params = env.delete(:custom_data) || {}
        filter_params_with_blacklist(params, env["action_dispatch.parameter_filter"])
      end

      # see https://raygun.com/documentation/product-guides/crash-reporting/api/
      def build_payload_hash(exception_instance, env = {}, user = nil)
        Raygun.log('building payload hash')
        custom_data = filter_custom_data(env) || {}
        exception_custom_data = if exception_instance.respond_to?(:raygun_custom_data)
                                  exception_instance.raygun_custom_data
                                else
                                  {}
                                end

        tags = env.delete(:tags) || []

        if rails_env
          tags << rails_env
        else
          tags << rack_env
        end

        combined_tags = []

        if Raygun.configuration.tags.is_a?(Proc)
          configuration_tags = Raygun.configuration.tags.call(exception_instance, env)
        else
          configuration_tags = Raygun.configuration.tags
        end

        combined_tags.concat(configuration_tags)

        Raygun.log('set tags')

        grouping_key = env.delete(:grouping_key)
        correlation_id = env.delete(:correlation_id)

        configuration_custom_data = Raygun.configuration.custom_data
        configured_custom_data = if configuration_custom_data.is_a?(Proc)
                                  configuration_custom_data.call(exception_instance, env)
                                 else
                                  configuration_custom_data
                                 end

        Raygun.log('set custom data')

        error_details = {
            machineName:    hostname,
            version:        version,
            client:         client_details,
            error:          error_details(exception_instance),
            userCustomData: exception_custom_data.merge(custom_data).merge(configured_custom_data),
            tags:           combined_tags.concat(tags).compact.uniq,
            request:        request_information(env),
            environment:    {
              utcOffset: Time.now.utc_offset / 3600
            }
        }

        # If we have breadcrumbs passed to us as context from another thread, then include them
        # Otherwise, use the default store (which is thread-local)
        ::Raygun::Breadcrumbs::Store.initialize(with: env.delete(:rg_breadcrumb_store)) if env.key?(:rg_breadcrumb_store) 

        store = ::Raygun::Breadcrumbs::Store
        error_details[:breadcrumbs] = store.take_until_size(MAX_BREADCRUMBS_SIZE).map(&:build_payload) if store.any?

        Raygun.log('set details and breadcrumbs')

        error_details.merge!(groupingKey: grouping_key) if grouping_key
        error_details.merge!(correlationId: correlation_id) if correlation_id

        user_details = if affected_user_present?(env)
                         user_information(env)
                       elsif user != nil
                         AffectedUser.information_hash(user)
                       end
        error_details.merge!(user: user_details) unless user_details == nil

        Raygun.log('set user details')

        if Raygun.configuration.filter_payload_with_whitelist
          Raygun.log('filtering payload with whitelist')
          error_details = filter_payload_with_whitelist(error_details)
        end

        {
          occurredOn: Time.now.utc.iso8601,
          details:    error_details
        }
      end

      def create_entry(payload_hash)
        Raygun.log('sending payload to api')

        self.class.post(
          "/entries",
          verify_peer: true,
          verify: true,
          headers: @headers,
          body: JSON.generate(payload_hash),
        )
      end

      def filter_params_with_blacklist(params_hash = {}, extra_filter_keys = nil)
        filter_parameters = Raygun.configuration.filter_parameters

        if filter_parameters.is_a? Proc
          filter_parameters.call(params_hash)
        else
          filter_keys = (Array(extra_filter_keys) + filter_parameters).map(&:to_s)

          filter_params_with_array(params_hash, filter_keys)
        end
      end

      def filter_payload_with_whitelist(payload_hash)
        shape = Raygun.configuration.whitelist_payload_shape

        if shape.is_a? Proc
          shape.call(payload_hash)
        else
          # Always keep the client hash, so force it to true here
          Services::ApplyWhitelistFilterToPayload.new.call(shape.merge(client: true), payload_hash)
        end
      end

      def filter_params_with_array(params_hash, filter_keys)
        # Recursive filtering of (nested) hashes
        (params_hash || {}).inject({}) do |result, (k, v)|
          result[k] = case v
          when Hash
            filter_params_with_array(v, filter_keys)
          else
            filter_keys.any? { |fk| /#{fk}/i === k.to_s } ? "[FILTERED]" : v
          end
          result
        end
      end

      def ip_address_from(env_hash)
        ENV_IP_ADDRESS_KEYS.each do |key_to_try|
          return env_hash[key_to_try] unless env_hash[key_to_try].nil? || env_hash[key_to_try] == ""
        end
        "(Not Available)"
      end

      def print_api_key_warning
        $stderr.puts(NO_API_KEY_MESSAGE)
      end
  end
end
