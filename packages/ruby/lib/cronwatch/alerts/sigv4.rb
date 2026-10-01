# frozen_string_literal: true

require "openssl"
require "uri"

module Cronwatch
  module Alerts
    # AWS Signature Version 4 with OpenSSL, for the SES channel, as the SDK's
    # alerts/sigv4.ts. Spec:
    # https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_sigv-create-signed-request.html
    # Checked against the AWS SigV4 test suite (test/provider_channels_test.rb).
    #
    # @api private
    module SigV4
      SPACES = Regexp.new("[#{JS::WHITESPACE}]+")

      module_function

      # Returns the headers to send: the given ones (lowercased) plus
      # x-amz-date, the session token when there is one, and authorization.
      # Host is signed but not returned; Net::HTTP sets it.
      def sign(method:, url:, headers:, body:, region:, service:, now:, access_key_id:, secret_access_key:, session_token: nil)
        uri = URI(url)
        amz_date = JS.iso(now).delete("-:").sub(/\.\d{3}/, "")
        day = amz_date[0, 8]
        out = {}
        headers.each { |name, value| out[name.to_s.downcase] = value.to_s }
        out["x-amz-date"] = amz_date
        out["x-amz-security-token"] = session_token if Provider.present?(session_token)

        signed = out.merge("host" => host(uri))
        names = signed.keys.sort
        canonical_headers = names.map { |n| "#{n}:#{JS.trim(signed[n]).gsub(SPACES, " ")}\n" }.join
        signed_headers = names.join(";")
        canonical_request = [
          method.to_s.upcase,
          canonical_uri(uri.path),
          canonical_query(uri.query),
          canonical_headers,
          signed_headers,
          Provider.sha256_hex(body),
        ].join("\n")
        scope = "#{day}/#{region}/#{service}/aws4_request"
        string_to_sign = ["AWS4-HMAC-SHA256", amz_date, scope, Provider.sha256_hex(canonical_request)].join("\n")

        key = hmac("AWS4#{secret_access_key}", day)
        key = hmac(key, region)
        key = hmac(key, service)
        key = hmac(key, "aws4_request")
        signature = OpenSSL::HMAC.hexdigest("SHA256", key, string_to_sign)

        out["authorization"] = "AWS4-HMAC-SHA256 Credential=#{access_key_id}/#{scope}, SignedHeaders=#{signed_headers}, Signature=#{signature}"
        out
      end

      # URL#host: the host, and the port when it is not the scheme's default.
      def host(uri)
        uri.port && uri.port != uri.default_port ? "#{uri.host}:#{uri.port}" : uri.host
      end

      def hmac(key, data)
        OpenSSL::HMAC.digest("SHA256", key, data)
      end

      # RFC 3986 encoding of every byte but the unreserved characters.
      def uri_encode(text)
        text.to_s.b.gsub(/[^A-Za-z0-9\-_.~]/n) { |c| format("%%%02X", c.ord) }.force_encoding(Encoding::UTF_8)
      end

      def canonical_uri(path)
        return "/" if path.nil? || path.empty?

        # The path is already encoded once; every AWS service but S3 expects each segment encoded again.
        path.split("/", -1).map { |segment| uri_encode(segment) }.join("/")
      end

      # The query as URLSearchParams reads it, each name and value encoded, sorted.
      def canonical_query(query)
        return "" if query.nil? || query.empty?

        pairs = URI.decode_www_form(query).map { |name, value| [uri_encode(name), uri_encode(value)] }
        pairs.sort.map { |name, value| "#{name}=#{value}" }.join("&")
      end
    end
  end
end
