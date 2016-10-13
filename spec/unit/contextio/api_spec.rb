require 'contextio/api'

describe ContextIO::API do
  describe ".version" do
    subject { ContextIO::API }

    it "uses API version 2.0" do
      expect(subject.version).to eq('2.0')
    end
  end

  describe "#version" do
    context "without version change" do
      subject { ContextIO::API.new(nil, nil) }

      it "uses API version 2.0" do
        expect(subject.version).to eq('2.0')
      end
    end

    context "with version change" do
      subject { ContextIO::API.new(nil, nil) }

      it "changes the API version used" do
        subject.version = '1.1'
        expect(subject.version).to eq('1.1')
      end
    end
  end

  describe ".base_url" do
    subject { ContextIO::API }

    it "is https://api.context.io" do
      expect(subject.base_url).to eq('https://api.context.io')
    end
  end

  describe "#base_url" do
    context "without base_url change" do
      subject { ContextIO::API.new(nil, nil) }

      it "is https://api.context.io" do
        expect(subject.base_url).to eq('https://api.context.io')
      end
    end

    context "with base_url change" do
      subject { ContextIO::API.new(nil, nil) }

      it "changes the base_url" do
        subject.base_url = 'https://api.example.com'
        expect(subject.base_url).to eq('https://api.example.com')
      end
    end
  end

  describe ".new" do
    subject { ContextIO::API.new('test_key', 'test_secret', {a:'b'}) }

    it "takes a key and a secret" do
      expect(subject.key).to eq('test_key')
    end

    it "takes a secret" do
      expect(subject.secret).to eq('test_secret')
    end

    it "takes an option hash" do
      expect(subject.opts).to eq(a:'b')
    end

    context "in 3-legged mode" do
      subject { ContextIO::API.new('test_key', 'test_secret', {access_token: 'at', access_token_secret: 'ats', a: 'b'})}

      it "recognizes the token and secret and move them aside" do
        expect(subject.access_token_opts).to eq(token: 'at', token_secret: 'ats')
        expect(subject.opts).to eq(a:'b')
      end
    end
  end

  describe "#path" do
    context "without params and default version" do
      subject { ContextIO::API.new(nil, nil).path('test_command') }

      it "puts the command in the path" do
        expect(subject).to eq('/2.0/test_command')
      end
    end

    context "without params and version change" do
      subject { ContextIO::API.new(nil, nil) }

      it "puts the command in the path" do
        subject.version = '2.5'
        expect(subject.path('test_command')).to eq('/2.5/test_command')
      end
    end

    context "with params" do
      subject { ContextIO::API.new(nil, nil).path('test_command', foo: 1, bar: %w(a b c)) }

      it "URL encodes the params" do
        expect(subject).to eq('/2.0/test_command?foo=1&bar=a%2Cb%2Cc')
      end
    end

    context "with a full URL" do
      subject { ContextIO::API.new(nil, nil).path('https://api.context.io/2.0/test_command') }

      it "strips out the command" do
        expect(subject).to eq('/2.0/test_command')
      end
    end

    context "with a full URL and version and base_url change" do
      subject { ContextIO::API.new(nil, nil) }

      it "strips out the command" do
        subject.version = '2.5'
        subject.base_url = 'https://api.example.com'
        expect(subject.path('https://api.example.com/2.5/test_command')).to eq('/2.5/test_command')
      end
    end
  end

  describe "#connection" do
    let(:api) { ContextIO::API.new('key', 'secret', access_token: 'at', access_token_secret: 'ats', timeout: 3, open_timeout: 1) }

    context "with supply_access_token false" do

      it "includes options" do
        conn = api.send(:connection, false)
        expect(conn.options[:timeout]).to eq(3)
        expect(conn.options[:open_timeout]).to eq(1)
      end

      it "does not include access token options" do
        allow_any_instance_of(::Faraday::Connection).to receive(:request)
        expect_any_instance_of(::Faraday::Connection).to receive(:request).
          with(:oauth, {consumer_key: 'key', consumer_secret: 'secret'})
        conn = api.send(:connection, false)
      end
    end

    context "with supply_access_token true" do
      it "includes access token options" do
        allow_any_instance_of(::Faraday::Connection).to receive(:request)
        expect_any_instance_of(::Faraday::Connection).to receive(:request).
          with(:oauth, {consumer_key: 'key', consumer_secret: 'secret',
            token: 'at', token_secret: 'ats'})
        conn = api.send(:connection, true)
      end
    end
  end

  describe "#request" do
    subject { ContextIO::API.new(nil, nil).request(:get, 'test') }

    context "with a timeout response" do
      before do
        WebMock.stub_request(
          :get,
          'https://api.context.io/2.0/test'
        ).to_timeout.then.to_return(
          status: 200,
          body: JSON.dump('yep' => 'noap'),
        )
      end

      it "parses the JSON response" do
        expect { ContextIO::API.new(nil, nil).request(:get, 'test') }.to raise_error(Faraday::Error::TimeoutError)
      end
    end

    context "with a good response" do
      before do
        WebMock.stub_request(
          :get,
          'https://api.context.io/2.0/test'
        ).to_return(
          status: 200,
          body: JSON.dump('a' => 'b', 'c' => 'd')
        )
      end

      it "parses the JSON response" do
        expect(subject).to eq('a' => 'b', 'c' => 'd')
      end
    end

    context "with a bad response that has a body" do
      before do
        WebMock.stub_request(
          :get,
          'https://api.context.io/2.0/test'
        ).to_return(
          status: 400,
          body: JSON.dump('type' => 'error', 'value' => 'nope')
        )
      end

      it "raises an API error with the body message" do
        expect { subject }.to raise_error(ContextIO::API::Error, 'nope')
      end
    end

    context "with a bad response that has a different body" do
      before do
        WebMock.stub_request(
          :get,
          'https://api.context.io/2.0/test'
        ).to_return(
          status: 400,
          body: JSON.dump('success' => false, 'feedback_code' => 'nope')
        )
      end

      it "raises an API error with the body message" do
        expect { subject }.to raise_error(ContextIO::API::Error, 'nope')
      end
    end

    context "with a bad response that has no body" do
      before do
        WebMock.stub_request(
          :get,
          'https://api.context.io/2.0/test'
        ).to_return(
          status: 400
        )
      end

      it "raises an API error with the header message" do
        expect { subject }.to raise_error(ContextIO::API::Error, 'HTTP 400 Error')
      end
    end
  end

  describe ".url_for" do
    it "delegates to ContextIO::API::URLBuilder" do
      expect(ContextIO::API::URLBuilder).to receive(:url_for).with('foo')

      ContextIO::API.url_for('foo')
    end
  end

  describe "#url_for" do
    subject { ContextIO::API.new('test_key', 'test_secret') }

    it "delegates to the class" do
      expect(ContextIO::API).to receive(:url_for).with('foo')

      subject.url_for('foo')
    end
  end
end
