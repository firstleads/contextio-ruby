require 'uri'
require 'json'
require 'faraday'
require 'faraday_middleware'

require 'contextio/api/url_builder'

class ContextIO
  # **For internal use only.** Users of this gem should not be using this
  # directly.  Represents the handle on the Context.IO API. It handles the
  # user's OAuth credentials with Context.IO and signing requests, etc.
  class API
    # For differentiating API errors from other errors that might happen during
    # requests.
    class Error < StandardError; end

    # @private
    VERSION = '2.0'

    # @return [String] The version of the Context.IO API this version of the
    #   gem is intended for use with.
    def self.version
      VERSION
    end

    # @private
    BASE_URL = 'https://api.context.io'
    DEFAULT_PARAMS = { :supply_access_token => true }

    # @return [String] The base URL the API is served from.
    def self.base_url
      BASE_URL
    end

    # @param [Object] resource The resource you want the URL for.
    #
    # @return [String] The URL for the resource in the API.
    def self.url_for(resource)
      ContextIO::API::URLBuilder.url_for(resource)
    end

    # @param [Object] resource The resource you want the URL for.
    #
    # @return [String] The URL for the resource in the API.
    def url_for(resource)
      ContextIO::API.url_for(resource)
    end

    def self.user_agent_string
      "contextio-ruby-#{ContextIO.version}"
    end

    def user_agent_string
      self.class.user_agent_string
    end

    attr_accessor :base_url, :version

    # @!attribute [r] key
    #   @return [String] The OAuth key for the user's Context.IO account.
    # @!attribute [r] secret
    #   @return [String] The OAuth secret for the user's Context.IO account.
    # @!attribute [r] opts
    #   @return [Hash] opts Optional options for OAuth connections.
    attr_reader :key, :secret, :opts

    # @param [String] key The user's OAuth key for their Context.IO account.
    # @param [String] secret The user's OAuth secret for their Context.IO account.
    # @param [Hash] opts Optional options for OAuth connections. ie. :timeout and :open_timeout are supported, as are :access_token and :access_token_secret for 3-legged OAuth.
    def initialize(key, secret, opts={})
      @oauth_opts = {token: key, token_secret: secret}
      @opts = opts || {}
      @access_token_opts = {}
      if @opts.include?(:access_token)
        @access_token_opts[:token] = @opts.delete(:access_token)
        @access_token_opts[:token_secret] = @opts.delete(:access_token_secret)
      end
      @base_url = self.class.base_url
      @version = self.class.version
    end

    # Generates the path for a resource_path and params hash for use with the API.
    #
    # @param [String] resource_path The resource_path or full resource URL for
    #   the resource being acted on.
    # @param [{String, Symbol => String, Symbol, Array<String, Symbol>}] params
    #   A Hash of the query parameters for the action represented by this path.
    def path(resource_path, params = {})
      "/#{version}/#{strip_resource_path(resource_path)}#{API.hash_to_url_params(params)}"
    end

    # Makes a request against the Context.IO API.
    #
    # @param [String, Symbol] method The HTTP verb for the request (lower case).
    # @param [String] resource_path The path to the resource in question.
    # @param [{String, Symbol => String, Symbol, Array<String, Symbol>}] params
    #   A Hash of the query parameters for the action represented by this
    #   request.
    #
    # @raise [API::Error] if the response code isn't in the 200 or 300 range.
    def request(method, resource_path, params = {})
      response = oauth_request(method, resource_path, params, { 'Accept' => 'application/json' })

      with_error_handling(response) do |response|
        parse_json(response.body)
      end
    end

    def raw_request(method, resource_path, params={})
      response = oauth_request(method, resource_path, params)

      with_error_handling(response) do |response|
        response.body
      end
    end

    private

    # Makes a request signed for OAuth, encoding parameters correctly, etc.
    #
    # @param [String, Symbol] method The HTTP verb for the request (lower case).
    # @param [String] resource_path The path to the resource in question.
    # @param [{String, Symbol => String, Symbol, Array<String, Symbol>}] params
    #   A Hash of the query parameters for the action represented by this
    #   request.
    # @param [{String, Symbol => String, Symbol, Array<String, Symbol>}] headers
    #   A Hash of headers to be merged with the default headers for making
    #   requests.
    #
    # @return [Faraday::Response] The response object from the request.
    def oauth_request(method, resource_path, params, headers=nil)
      normalized_params = params.inject({}) do |normalized_params, (key, value)|
        normalized_params[key.to_sym] = value
        normalized_params
      end

      normalized_params = DEFAULT_PARAMS.merge(normalized_params)
      supply_access_token = normalized_params.delete(:supply_access_token)

      connection(supply_access_token).send(method, path(resource_path), normalized_params, headers)
    end

    # So that we can accept full URLs, this strips the domain and version number
    # out and returns just the resource path.
    #
    # @param [#to_s] resource_path The full URL or path for a resource.
    #
    # @return [String] The resource path.
    def strip_resource_path(resource_path)
      resource_path.to_s.gsub("#{base_url}/#{version}/", '')
    end

    # Context.IO's API expects query parameters that are arrays to be comma
    # separated, rather than submitted more than once. This munges those arrays
    # and then URL-encodes the whole thing into a query string.
    #
    # @param [{String, Symbol => String, Symbol, Array<String, Symbol>}] params
    #   A Hash of the query parameters.
    #
    # @return [String] A URL-encoded version of the query parameters.
    def self.hash_to_url_params(params = {})
      return '' if params.empty?

      params = params.inject({}) do |memo, (k, v)|
        memo[k] = Array(v).join(',')

        memo
      end

      "?#{URI.encode_www_form(params)}"
    end

    # @!attribute [r] connection
    # @return [Faraday::Connection] A handle on the Faraday connection object.
    def connection(supply_access_token)
      @connection ||= Faraday::Connection.new(base_url) do |faraday|
        faraday.headers['User-Agent'] = user_agent_string

        if supply_access_token
          faraday.request :oauth, @oauth_opts.merge(@access_token_opts)
        else
          faraday.request :oauth, @oauth_opts
        end
        faraday.request :url_encoded
        faraday.request :retry, max: 0

        faraday.adapter Faraday.default_adapter
      end
    end

    # Errors can come in a few shapes and we want to detect them and extract the
    # useful information. If no errors are found, it calls the provided block
    # and passes the response through.
    #
    # @param [Faraday::Response] response A response object from making a request to the
    #   API with Faraday.
    #
    # @raise [API::Error] if the response code isn't in the 200 or 300 range.
    def with_error_handling(response, &block)
      return block.call(response) if response.success?

      parsed_body = parse_json(response.body)
      message = determine_best_error_message(parsed_body) || "HTTP #{response.status} Error"

      raise API::Error, message
    end

    # Parses JSON if there's valid JSON passed in.
    #
    # @param [String] document A string you suspect may be a JSON document.
    #
    # @return [Hash, Array, Nil] Either a parsed version of the JSON document or
    #   nil, if the document wasn't valid JSON.
    def parse_json(document)
      return JSON.parse(document.to_s)
    rescue JSON::ParserError => e
      return nil
    end

    # Given a parsed JSON body from an error response, figures out if it can
    # pull useful information therefrom.
    #
    # @param [Hash] parsed_body A Hash parsed from a JSON document that may
    #   describe an error condition.
    #
    # @return [String, Nil] If it can, it will return a human-readable
    #   error-describing String. Otherwise, nil.
    def determine_best_error_message(parsed_body)
      return unless parsed_body.respond_to?(:[])

      if parsed_body['type'] == 'error'
        return parsed_body['value']
      elsif parsed_body.has_key?('success') && !parsed_body['success']
        return [parsed_body['feedback_code'], parsed_body['connectionLog']].compact.join("\n")
      end
    end
  end
end
