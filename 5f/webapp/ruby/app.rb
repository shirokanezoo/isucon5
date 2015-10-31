require 'sinatra/base'
require 'sinatra/contrib'
require 'pg'
require 'tilt/erubis'
require 'erubis'
require 'httpclient'
require 'openssl'
require 'expeditor'
require 'redis'
require 'hiredis'
require 'redis/connection/hiredis'
require 'oj'
require 'oj_mimic_json'
require 'msgpack'

# bundle config build.pg --with-pg-config=<path to pg_config>
# bundle install

module Isucon5f
  module TimeWithoutZone
    def to_s
      strftime("%F %H:%M:%S")
    end
  end
  ::Time.prepend TimeWithoutZone
end

class Isucon5f::Endpoint
  LIST = {}

  def self.get(name)
    LIST[name]
  end

  def initialize(name, method, token_type, token_key, uri)
    @name, @method, @token_type, @token_key, @uri = name, method, token_type, token_key, uri
    @ssl = uri.start_with?('https://')

    LIST[@name] = self
  end
  attr_reader :name, :method, :token_type, :token_key, :uri

  def fetch(conf)
    headers = {}
    params = (conf['params'] && conf['params'].dup) || {}
    case token_type
    when 'header' then headers[token_key] = conf['token']
    when 'param' then params[token_key] = conf['token']
    end
    call_uri = sprintf(uri, *conf['keys'])

    client = HTTPClient.new
    if @ssl
      client.ssl_config.verify_mode = OpenSSL::SSL::VERIFY_NONE
    end
    fetcher = case method
              when 'GET' then client.method(:get_content)
              when 'POST' then client.method(:post_content)
              else
                raise "unknown method #{method}"
              end
    res = fetcher.call(call_uri, params, headers)

    JSON.parse(res)
  end
end

Isucon5f::Endpoint.new('ken', 'GET', nil, nil, 'http://api.five-final.isucon.net:8080/%s')
Isucon5f::Endpoint.new('ken2', 'GET', nil, nil, 'http://api.five-final.isucon.net:8080/')
Isucon5f::Endpoint.new('surname', 'GET', nil, nil, 'http://api.five-final.isucon.net:8081/surname')
Isucon5f::Endpoint.new('givenname', 'GET', nil, nil, 'http://api.five-final.isucon.net:8081/givenname')
Isucon5f::Endpoint.new('tenki', 'GET', 'param', 'zipcode', 'http://api.five-final.isucon.net:8988/')
Isucon5f::Endpoint.new('perfectsec', 'GET', 'header', 'X-PERFECT-SECURITY-TOKEN', 'https://api.five-final.isucon.net:8443/tokens')
Isucon5f::Endpoint.new('perfectsec_attacked', 'GET', 'header', 'X-PERFECT-SECURITY-TOKEN', 'https://api.five-final.isucon.net:8443/attacked_list')

class Isucon5f::WebApp < Sinatra::Base
  use Rack::Session::Cookie, secret: (ENV['ISUCON5_SESSION_SECRET'] || 'tonymoris')
  set :erb, escape_html: true
  set :public_folder, File.expand_path('../../static', __FILE__)

  SALT_CHARS = [('a'..'z'),('A'..'Z'),('0'..'9')].map(&:to_a).reduce(&:+)

  helpers do
    def config
      @config ||= {
        db: {
          host: ENV['ISUCON5_DB_HOST'] || 'localhost',
          port: ENV['ISUCON5_DB_PORT'] && ENV['ISUCON5_DB_PORT'].to_i,
          username: ENV['ISUCON5_DB_USER'] || 'isucon',
          password: ENV['ISUCON5_DB_PASSWORD'],
          database: ENV['ISUCON5_DB_NAME'] || 'isucon5f',
        },
      }
    end

    def db
      return Thread.current[:isucon5_db] if Thread.current[:isucon5_db]
      conn = PG.connect(
        host: config[:db][:host],
        port: config[:db][:port],
        user: config[:db][:username],
        password: config[:db][:password],
        dbname: config[:db][:database],
        connect_timeout: 3600
      )
      Thread.current[:isucon5_db] = conn
      conn
    end

    def redis_host
      ENV['REDIS_HOST'] || 'localhost'
    end

    def redis
      return Thread.current[:redis] if Thread.current[:redis]
      Thread.current[:redis] = Redis.new(
        host: redis_host,
        port: ENV['REDIS_PORT'] || 6379,
        driver: :hiredis
      )
    end

    def insert_subscription(user_id)
      redis.set("subscription/#{user_id}", "{}")
    end

    def update_subscription(user_id, params)
      redis.set("subscription/#{user_id}", params.to_msgpack)
    end

    def get_subscription(user_id)
      MessagePack.unpack(redis.get("subscription/#{user_id}") || "\x80")
    end

    def authenticate(email, password)
      query = <<SQL
SELECT id, email, grade FROM users WHERE email=$1 AND passhash=digest(salt || $2, 'sha512')
SQL
      user = nil
      db.exec_params(query, [email, password]) do |result|
        result.each do |tuple|
          user = {id: tuple['id'].to_i, email: tuple['email'], grade: tuple['grade']}
        end
      end
      session[:user_id] = user[:id] if user
      user
    end

    def current_user
      return @user if @user
      return nil unless session[:user_id]
      @user = nil
      db.exec_params('SELECT id,email,grade FROM users WHERE id=$1', [session[:user_id]]) do |r|
        r.each do |tuple|
          @user = {id: tuple['id'].to_i, email: tuple['email'], grade: tuple['grade']}
        end
      end
      session.clear unless @user
      @user
    end

    def generate_salt
      salt = ''
      32.times do
        salt << SALT_CHARS[rand(SALT_CHARS.size)]
      end
      salt
    end
  end

  get '/signup' do
    session.clear
    erb :signup
  end

  post '/signup' do
    email, password, grade = params['email'], params['password'], params['grade']
    salt = generate_salt
    insert_user_query = <<SQL
INSERT INTO users (email,salt,passhash,grade) VALUES ($1,$2,digest($3 || $4, 'sha512'),$5) RETURNING id
SQL
    db.transaction do |conn|
      user_id = conn.exec_params(insert_user_query, [email,salt,salt,password,grade]).values.first.first
      insert_subscription(user_id)
    end
    redirect '/login'
  end

  post '/cancel' do
    redirect '/signup'
  end

  get '/login' do
    session.clear
    erb :login
  end

  post '/login' do
    authenticate params['email'], params['password']
    halt 403 unless current_user
    redirect '/'
  end

  get '/logout' do
    session.clear
    redirect '/login'
  end

  get '/' do
    unless current_user
      return redirect '/login'
    end
    erb :main, locals: {user: current_user}
  end

  get '/user.js' do
    halt 403 unless current_user
    erb :userjs, content_type: 'application/javascript', locals: {grade: current_user[:grade]}
  end

  get '/modify' do
    user = current_user
    halt 403 unless user

    arg = get_subscription(user[:id])
    erb :modify, locals: {user: user, arg: arg}
  end

  post '/modify' do
    user = current_user
    halt 403 unless user

    service = params["service"]
    token = params.has_key?("token") ? params["token"].strip : nil
    keys = params.has_key?("keys") ? params["keys"].strip.split(/\s+/) : nil
    param_name = params.has_key?("param_name") ? params["param_name"].strip : nil
    param_value = params.has_key?("param_value") ? params["param_value"].strip : nil

    db.transaction do |conn|
      arg = get_subscription(user[:id])
      arg[service] ||= {}
      arg[service]['token'] = token if token
      arg[service]['keys'] = keys if keys
      if param_name && param_value
        arg[service]['params'] ||= {}
        arg[service]['params'][param_name] = param_value
      end
      update_subscription(user[:id], arg)
    end
    redirect '/modify'
  end

  def fetch_api(method, uri, headers, params)
    client = HTTPClient.new
    if uri.start_with? "https://"
      client.ssl_config.verify_mode = OpenSSL::SSL::VERIFY_NONE
    end
    fetcher = case method
              when 'GET' then client.method(:get_content)
              when 'POST' then client.method(:post_content)
              else
                raise "unknown method #{method}"
              end
    res = fetcher.call(uri, params, headers)
    JSON.parse(res)
  end

  get '/data' do
    unless user = current_user
      halt 403
    end

    arg = get_subscription(user[:id])

    data = arg.map do |service, conf|
      Expeditor::Command.new do
        endpoint = Isucon5f::Endpoint.get(service)
        {"service" => service, "data" => endpoint.fetch(conf)}
      end
    end

    data.each(&:start)
    json data.map(&:get)
  end

  get '/initialize' do
    puts "===> Initialize DB    : #{Time.now.to_s}"
    file = File.expand_path("../../sql/initialize.sql", __FILE__)
    system("psql", "-f", file, "isucon5f")

    puts "===> Initialize Redis : #{Time.now.to_s}"
    redis.flushall

    result = db.exec_params('SELECT * FROM subscriptions') do |result|
      result.values
    end

    redis.pipelined do
      result.each do |row|
        update_subscription(row[0], JSON.parse(row[1]))
      end
    end

    ""
  end
end
