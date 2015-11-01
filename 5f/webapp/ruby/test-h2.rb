require 'logger'
require 'uri'
require 'openssl'
require 'socket'
require 'http/2'
require 'thread'

# this doesn't work

class IsuHttp2
  LIST = {}
  def self.for(uri)
    key = [uri.host,uri.port].join(':')
    cl = LIST[key]
    if cl.nil? || (cl && cl.ended?)
      LIST[key] = self.new(uri.host, uri.hostname, uri.port)
    else
      cl
    end
  end

  def initialize(host, hostname, port)
    @host, @hostname, @port = host, hostname, port
    @ended = false
    @streams = {}
    @lock = Mutex.new
    conn
    h2.settings(settings_max_concurrent_streams: 100)
    start_reading
  end

  def h2
    @h2 ||= HTTP2::Client.new.tap do |cl|
      cl.on(:goaway) do |d|
        log "goaway #{d.inspect}"
        @ended = true
      end

      cl.on(:frame) do |bytes|
        log "-> #{bytes.inspect}"
        # puts "Sending bytes: #{bytes.unpack("H*").first}"
        conn.print bytes
        conn.flush
      end

      cl.on(:frame_sent) do |frame|
        log "Sent frame: #{frame.inspect}"
      end

      cl.on(:frame_received) do |frame|
        log "Received frame: #{frame.inspect}"
      end
    end
  end

  def conn
    @conn ||= begin
      h2
      @tcp = TCPSocket.new(@host, @port.to_i)
      ctx = OpenSSL::SSL::SSLContext.new
      ctx.verify_mode = OpenSSL::SSL::VERIFY_NONE

      ctx.npn_protocols = %w(h2)
      ctx.npn_select_cb = lambda do |protocols|
        'h2'.freeze
      end

      sock = OpenSSL::SSL::SSLSocket.new(@tcp, ctx)
      sock.sync_close = true
      sock.hostname = @hostname
      sock.connect
      sock
    end
  end

  def start_reading
    conn
    Thread.new do
      begin
        loop do
          log "wait"
          rs, _, _ = IO.select([tcp])

          data = conn.read_nonblock(1024)

          log "<- #{data.inspect}"
          h2 << data

          break if conn.closed? || conn.eof?
        end
        log "bye"
      rescue Exception => err
        $stderr.puts "connection reader encountered error: #{err.inspect}\n\t#{err.backtrace.join("\n\t")}"
        close
      end
    end.abort_on_exception = true
  end

  def close
    @lock.synchronize do
      return if @ended
      @ended = true
      h2.goaway
      conn.close
    end
  end

  def get(uri, headers = {})
    stream = @lock.synchronize do
      raise 'ended' if @ended
      new_stream
    end

    head = {
      ':scheme' => uri.scheme,
      ':method' => 'GET',
      ':authority' => [uri.host, uri.port].join(':'),
      ':path' => uri.path,
    }.merge(headers)

    stream.stream.headers(head, end_stream: true)
  end

  def new_stream
    h2_stream = h2.new_stream

    h2_stream.on(:close) do
      log "stream closed", h2_stream
      @lock.synchronize do
        @streams.delete h2_stream.id
      end
    end

    h2_stream.on(:half_close) do
      log 'closing client-end of the stream', h2_stream
    end

    stream = Stream.new(h2, h2_stream)
    @streams[h2_stream.id] = stream
  end

  def log(msg, stream = nil)
    $stderr.puts "#{@host}:#{@port}[#{stream ? stream.id : :conn}] #{msg}"
  end

  class Stream
    def initialize(h2, h2_stream)
      @stream, @queue = h2_stream, Queue.new
      @headers = {}
      @data = []

      stream.on(:headers) do |hs|
        p [:headers, hs]
        hs.each do |k,v|
          (@headers[k] ||= []) << v
        end
      end
      p :hi
      stream.on(:data) do |d|
        h2.window_update(1024)
        p [:data, d]
        @data << d
      end
    end


    attr_reader :stream, :queue, :headers, :data
  end
end

headers = {'x-perfect-security-token' => '98275714642d262ada3561956ff9824a51d798af'}
#url = 'https://api.five-final.isucon.net:8443/attacked_list'
url = 'https://www.google.com'
uri = URI(url)

ih2 = IsuHttp2.for(uri)
ih2.get(uri, headers)

sleep 10
