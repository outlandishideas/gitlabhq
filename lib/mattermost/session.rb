module Mattermost
  class NoSessionError < Mattermost::Error
    def message
      'No session could be set up, is Mattermost configured with Single Sign On?'
    end
  end

  ConnectionError = Class.new(Mattermost::Error)

  # This class' prime objective is to obtain a session token on a Mattermost
  # instance with SSO configured where this GitLab instance is the provider.
  #
  # The process depends on OAuth, but skips a step in the authentication cycle.
  # For example, usually a user would click the 'login in GitLab' button on
  # Mattermost, which would yield a 302 status code and redirects you to GitLab
  # to approve the use of your account on Mattermost. Which would trigger a
  # callback so Mattermost knows this request is approved and gets the required
  # data to create the user account etc.
  #
  # This class however skips the button click, and also the approval phase to
  # speed up the process and keep it without manual action and get a session
  # going.
  class Session
    include Doorkeeper::Helpers::Controller
    include HTTParty

    LEASE_TIMEOUT = 60

    base_uri Settings.mattermost.host

    attr_accessor :current_resource_owner, :token

    def initialize(current_user)
      @current_resource_owner = current_user
    end

    def with_session
      with_lease do
        raise Mattermost::NoSessionError unless create

        begin
          yield self
        rescue Errno::ECONNREFUSED
          raise Mattermost::NoSessionError
        ensure
          destroy
        end
      end
    end

    # Next methods are needed for Doorkeeper
    def pre_auth
      @pre_auth ||= Doorkeeper::OAuth::PreAuthorization.new(
        Doorkeeper.configuration, server.client_via_uid, params)
    end

    def authorization
      @authorization ||= strategy.request
    end

    def strategy
      @strategy ||= server.authorization_request(pre_auth.response_type)
    end

    def request
      @request ||= OpenStruct.new(parameters: params)
    end

    def params
      Rack::Utils.parse_query(oauth_uri.query).symbolize_keys
    end

    def get(path, options = {})
      handle_exceptions do
        self.class.get(path, options.merge(headers: @headers))
      end
    end

    def post(path, options = {})
      handle_exceptions do
        self.class.post(path, options.merge(headers: @headers))
      end
    end

    private

    def create
      return unless oauth_uri
      return unless token_uri

      @token = request_token
      @headers = {
        Authorization: "Bearer #{@token}"
      }

      @token
    end

    def destroy
      post('/api/v3/users/logout')
    end

    def oauth_uri
      return @oauth_uri if defined?(@oauth_uri)

      @oauth_uri = nil

      response = get("/api/v3/oauth/gitlab/login", follow_redirects: false)
      return unless 300 <= response.code && response.code < 400

      redirect_uri = response.headers['location']
      return unless redirect_uri

      @oauth_uri = URI.parse(redirect_uri)
    end

    def token_uri
      @token_uri ||=
        if oauth_uri
          authorization.authorize.redirect_uri if pre_auth.authorizable?
        end
    end

    def request_token
      response = get(token_uri, follow_redirects: false)

      if 200 <= response.code && response.code < 400
        response.headers['token']
      end
    end

    def with_lease
      lease_uuid = lease_try_obtain
      raise NoSessionError unless lease_uuid

      begin
        yield
      ensure
        Gitlab::ExclusiveLease.cancel(lease_key, lease_uuid)
      end
    end

    def lease_key
      "mattermost:session"
    end

    def lease_try_obtain
      lease = ::Gitlab::ExclusiveLease.new(lease_key, timeout: LEASE_TIMEOUT)
      lease.try_obtain
    end

    def handle_exceptions
      yield
    rescue HTTParty::Error => e
      raise Mattermost::ConnectionError.new(e.message)
    rescue Errno::ECONNREFUSED => e
      raise Mattermost::ConnectionError.new(e.message)
    end
  end
end
