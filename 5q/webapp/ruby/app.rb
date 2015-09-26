require 'sinatra/base'
require 'mysql2'
require 'mysql2-cs-bind'
require 'tilt/erubis'
require 'erubis'
require 'redis'
require 'json'

module MysqlMonkeyPatch
  def xquery(query, *args)
    s = Time.now
    r = super
    e = Time.now

    c0 = caller_locations[0]
    c1 = caller_locations[1]

    cstr0 = "#{File.basename(c0.path)}:#{c0.lineno}:#{c0.label}" if c0
    cstr1 = "#{File.basename(c1.path)}:#{c1.lineno}:#{c1.label}" if c1

    puts "type:mysql\tmode:xquery\tms:#{(e-s) * 1000}\tquery:#{query}\targs:#{args.inspect}\tcaller0:#{cstr0}\tcaller1:#{cstr1}"
    r
  end

  def query(query, *args)
    s = Time.now
    r = super
    e = Time.now

    c0 = caller_locations[0]
    return r if c0.label == 'xquery'.freeze

    c1 = caller_locations[1]
    cstr0 = "#{File.basename(c0.path)}:#{c0.lineno}:#{c0.label}" if c0
    cstr1 = "#{File.basename(c1.path)}:#{c1.lineno}:#{c1.label}" if c1

    puts "type:mysql\tmode:query\tms:#{(e-s) * 1000}\tquery:#{query}\targs:#{args.inspect}\tcaller0:#{cstr0}\tcaller1:#{cstr1}"
    r
  end

end

module Isucon5
  class AuthenticationError < StandardError; end
  class PermissionDenied < StandardError; end
  class ContentNotFound < StandardError; end
  module TimeWithoutZone
    def to_s
      strftime("%F %H:%M:%S")
    end
  end
  ::Time.prepend TimeWithoutZone
end

class Isucon5::WebApp < Sinatra::Base
  use Rack::Session::Cookie
  set :erb, escape_html: true
  set :public_folder, File.expand_path('../../static', __FILE__)
  #set :sessions, true
  set :session_secret, ENV['ISUCON5_SESSION_SECRET'] || 'beermoris'
  set :protection, true

  helpers do
    def config
      @config ||= {
        db: {
          host: ENV['ISUCON5_DB_HOST'] || 'localhost',
          port: ENV['ISUCON5_DB_PORT'] && ENV['ISUCON5_DB_PORT'].to_i,
          username: ENV['ISUCON5_DB_USER'] || 'root',
          password: ENV['ISUCON5_DB_PASSWORD'],
          database: ENV['ISUCON5_DB_NAME'] || 'isucon5q',
        },
        redis: {
          host: ENV['ISUCON5_REDIS_HOST'] || 'localhost',
          port: (ENV['ISUCON5_REDIS_PORT'] || 6379).to_i,
          db: (ENV['ISUCON5_REDIS_DB'] || 0).to_i
        }
      }
    end

    def db
      return Thread.current[:isucon5_db] if Thread.current[:isucon5_db]
      client = Mysql2::Client.new(
        host: config[:db][:host],
        port: config[:db][:port],
        username: config[:db][:username],
        password: config[:db][:password],
        database: config[:db][:database],
        reconnect: true,
      )
      client.query_options.merge!(symbolize_keys: true)
      client.extend(MysqlMonkeyPatch) unless ENV['ISUCON5_DISABLE_LOGS'] == '1'

      Thread.current[:isucon5_db] = client
      client
    end

    def redis
      Thread.current[:isucon5_redis] ||= Redis.new(config[:redis])
    end

    def cache(key, &block)
      key = "isucon5-#{key}"
      ret = redis.get(key)
      ret && ret.to_s.size > 0 ?  ret = JSON.parse(ret, symbolize_names: true) : ret = nil

      ret ||= begin
                val = block.call
                redis.set(key, JSON.dump(val)) unless val.nil?
                val
              end
      ret
    end

    def authenticate(email, password)
      query = <<SQL
SELECT u.id AS id, u.account_name AS account_name, u.nick_name AS nick_name, u.email AS email
FROM users u
JOIN salts s ON u.id = s.user_id
WHERE u.email = ? AND u.passhash = SHA2(CONCAT(?, s.salt), 512)
SQL
      result = db.xquery(query, email, password).first
      unless result
        raise Isucon5::AuthenticationError
      end
      session[:user_id] = result[:id]
      result
    end

    def current_user
      return @user if @user
      unless session[:user_id]
        return nil
      end

      @user = cache("current/user/#{session[:user_id]}") do
        db.xquery('SELECT id, account_name, nick_name, email FROM users WHERE id=?', session[:user_id]).first
      end

      unless @user
        session[:user_id] = nil
        session.clear
        raise Isucon5::AuthenticationError
      end
      @user
    end

    def authenticated!
      unless current_user
        redirect '/login'
      end
    end

    def get_user(user_id)
      user = cache("user/id/#{user_id}") do
        db.xquery('SELECT * FROM users WHERE id = ?', user_id).first
      end

      raise Isucon5::ContentNotFound unless user
      user
    end

    def user_from_account(account_name)
      user = cache("user/account_name/#{account_name}") do
        db.xquery('SELECT * FROM users WHERE account_name = ?', account_name).first
      end

      raise Isucon5::ContentNotFound unless user
      user
    end

    def current_friends
      @current_friends ||= begin
        user_id = session[:user_id]
        query = 'SELECT one, another, created_at FROM relations WHERE one = ? OR another = ?'
        rows = db.xquery(query, user_id, user_id)
        Hash[rows.map { |_| [_[:one] == user_id ? _[:another] : _[:one], _[:created_at]] }]
      end
    end

    def is_friend?(another_id)
      !!current_friends[another_id]
    end

    def is_friend_account?(account_name)
      is_friend?(user_from_account(account_name)[:id])
    end

    def permitted?(another_id)
      another_id == current_user[:id] || is_friend?(another_id)
    end

    def mark_footprint(user_id)
      stamp(user_id)
    end

    def stamp(user_id, owner_id: nil, at: nil)
      owner_id ||= current_user[:id]

      return if owner_id.nil? || user_id == owner_id

      initialize_footprints(user_id)

      redis.zadd("isucon5-footprints/#{user_id}", (at || Time.now).to_i, owner_id)
    end

    def footprints_by(user_id, count = 50)
      initialize_footprints(user_id)

      fps = redis.zrevrange("isucon5-footprints/#{user_id}", 0, count, with_scores: true)
      fps.map do |fp|
        {
          owner_id: fp[0].to_i,
          updated: Time.at(fp[1])
        }.merge(get_user(fp[0].to_i))
      end
    end

    def initialize_footprints(user_id)
      return if redis.get("isucon5-init/footprints/#{user_id}")
      redis.set("isucon5-init/footprints/#{user_id}", "1")

      query = <<-SQL
        SELECT user_id, owner_id, DATE(created_at) AS date, MAX(created_at) as updated
        FROM footprints
        WHERE user_id = ?
        GROUP BY user_id, owner_id, DATE(created_at)
        ORDER BY updated DESC
        LIMIT 50
      SQL

      footprints = db.xquery(query, user_id)
      redis.multi do
        footprints.each do |fp|
          stamp(fp[:user_id], owner_id: fp[:owner_id], at: fp[:updated])
        end
      end
    end

    PREFS = %w(
      未入力
      北海道 青森県 岩手県 宮城県 秋田県 山形県 福島県 茨城県 栃木県 群馬県 埼玉県 千葉県 東京都 神奈川県 新潟県 富山県
      石川県 福井県 山梨県 長野県 岐阜県 静岡県 愛知県 三重県 滋賀県 京都府 大阪府 兵庫県 奈良県 和歌山県 鳥取県 島根県
      岡山県 広島県 山口県 徳島県 香川県 愛媛県 高知県 福岡県 佐賀県 長崎県 熊本県 大分県 宮崎県 鹿児島県 沖縄県
    )
    def prefectures
      PREFS
    end
  end

  error Isucon5::AuthenticationError do
    session[:user_id] = nil
    halt 401, erubis(:login, layout: false, locals: { message: 'ログインに失敗しました' })
  end

  error Isucon5::PermissionDenied do
    halt 403, erubis(:error, locals: { message: '友人のみしかアクセスできません' })
  end

  error Isucon5::ContentNotFound do
    halt 404, erubis(:error, locals: { message: '要求されたコンテンツは存在しません' })
  end

  get '/login' do
    session.clear
    erb :login, layout: false, locals: { message: '高負荷に耐えられるSNSコミュニティサイトへようこそ!' }
  end

  post '/login' do
    authenticate params['email'], params['password']
    redirect '/'
  end

  get '/logout' do
    session[:user_id] = nil
    session.clear
    redirect '/login'
  end

  get '/' do
    authenticated!

    profile = db.xquery('SELECT * FROM profiles WHERE user_id = ?', current_user[:id]).first

    entries_query = 'SELECT id,user_id,private,title,created_at FROM entries WHERE user_id = ? ORDER BY created_at LIMIT 5'
    entries = db.xquery(entries_query, current_user[:id])
      .map{ |entry| entry[:is_private] = (entry[:private] == 1); entry }

    comments_for_me_query = <<SQL
SELECT c.id AS id, c.entry_id AS entry_id, c.user_id AS user_id, c.comment AS comment, c.created_at AS created_at
FROM comments c
JOIN entries e ON c.entry_id = e.id
WHERE e.user_id = ?
ORDER BY c.created_at DESC
LIMIT 10
SQL
    comments_for_me = db.xquery(comments_for_me_query, current_user[:id])

    entries_of_friends = []
    db.query('SELECT id,user_id,private,title,created_at FROM entries ORDER BY created_at DESC LIMIT 1000').each do |entry|
      next unless is_friend?(entry[:user_id]) # TODO
      entries_of_friends << entry
      break if entries_of_friends.size >= 10
    end

    comments_of_friends = []
    db.query('SELECT comments.*, entries.private AS entry_private, entries.user_id AS entry_user_id FROM comments LEFT JOIN entries ON comments.entry_id = entries.id ORDER BY comments.created_at DESC LIMIT 1000').each do |comment|
      next unless is_friend?(comment[:user_id])
      entry = {user_id: comment[:entry_user_id]}
      entry[:is_private] = (comment[:entry_private] == 1)
      comment[:entry] = entry
      next if entry[:is_private] && !permitted?(entry[:user_id])
      comments_of_friends << comment
      break if comments_of_friends.size >= 10
    end

    footprints = footprints_by(current_user[:id], 10)

    locals = {
      profile: profile || {},
      entries: entries,
      comments_for_me: comments_for_me,
      entries_of_friends: entries_of_friends,
      comments_of_friends: comments_of_friends,
      friends: current_friends,
      footprints: footprints
    }
    erb :index, locals: locals
  end

  get '/profile/:account_name' do
    authenticated!
    owner = user_from_account(params['account_name'])
    prof = db.xquery('SELECT * FROM profiles WHERE user_id = ?', owner[:id]).first
    prof = {} unless prof
    query = if permitted?(owner[:id])
              'SELECT * FROM entries WHERE user_id = ? ORDER BY created_at LIMIT 5'
            else
              'SELECT * FROM entries WHERE user_id = ? AND private=0 ORDER BY created_at LIMIT 5'
            end
    entries = db.xquery(query, owner[:id])
      .map{ |entry| entry[:is_private] = (entry[:private] == 1); entry }
    mark_footprint(owner[:id])
    erb :profile, locals: { owner: owner, profile: prof, entries: entries, private: permitted?(owner[:id]) }
  end

  post '/profile/:account_name' do
    authenticated!
    if params['account_name'] != current_user[:account_name]
      raise Isucon5::PermissionDenied
    end
    args = [params['first_name'], params['last_name'], params['sex'], params['birthday'], params['pref']]

    prof = db.xquery('SELECT * FROM profiles WHERE user_id = ?', current_user[:id]).first
    if prof
      query = <<SQL
UPDATE profiles
SET first_name=?, last_name=?, sex=?, birthday=?, pref=?, updated_at=CURRENT_TIMESTAMP()
WHERE user_id = ?
SQL
      args << current_user[:id]
    else
      query = <<SQL
INSERT INTO profiles (user_id,first_name,last_name,sex,birthday,pref) VALUES (?,?,?,?,?,?)
SQL
      args.unshift(current_user[:id])
    end
    db.xquery(query, *args)
    redirect "/profile/#{params['account_name']}"
  end

  get '/diary/entries/:account_name' do
    authenticated!
    owner = user_from_account(params['account_name'])
    query = if permitted?(owner[:id])
              'SELECT * FROM entries WHERE user_id = ? ORDER BY created_at DESC LIMIT 20'
            else
              'SELECT * FROM entries WHERE user_id = ? AND private=0 ORDER BY created_at DESC LIMIT 20'
            end
    entries = db.xquery(query, owner[:id])
      .map{ |entry| entry[:is_private] = (entry[:private] == 1);  entry }
    mark_footprint(owner[:id])
    erb :entries, locals: { owner: owner, entries: entries, myself: (current_user[:id] == owner[:id]) }
  end

  get '/diary/entry/:entry_id' do
    authenticated!
    entry = db.xquery('SELECT * FROM entries WHERE id = ?', params['entry_id']).first
    raise Isucon5::ContentNotFound unless entry
    entry[:is_private] = (entry[:private] == 1)
    owner = get_user(entry[:user_id])
    if entry[:is_private] && !permitted?(owner[:id])
      raise Isucon5::PermissionDenied
    end
    comments = db.xquery('SELECT * FROM comments WHERE entry_id = ?', entry[:id])
    mark_footprint(owner[:id])
    erb :entry, locals: { owner: owner, entry: entry, comments: comments }
  end

  post '/diary/entry' do
    authenticated!
    query = 'INSERT INTO entries (user_id, private, body) VALUES (?,?,?)'
    body = (params['title'] || "タイトルなし") + "\n" + params['content']
    db.xquery(query, current_user[:id], (params['private'] ? '1' : '0'), body)
    redirect "/diary/entries/#{current_user[:account_name]}"
  end

  post '/diary/comment/:entry_id' do
    authenticated!
    entry = db.xquery('SELECT * FROM entries WHERE id = ?', params['entry_id']).first
    unless entry
      raise Isucon5::ContentNotFound
    end
    entry[:is_private] = (entry[:private] == 1)
    if entry[:is_private] && !permitted?(entry[:user_id])
      raise Isucon5::PermissionDenied
    end
    query = 'INSERT INTO comments (entry_id, user_id, comment) VALUES (?,?,?)'
    db.xquery(query, entry[:id], current_user[:id], params['comment'])
    redirect "/diary/entry/#{entry[:id]}"
  end

  get '/footprints' do
    authenticated!

    footprints = footprints_by(current_user[:id], 50)
    erb :footprints, locals: { footprints: footprints }
  end

  get '/friends' do
    authenticated!
    query = 'SELECT * FROM relations WHERE one = ? OR another = ? ORDER BY created_at DESC'
    friends = {}
    db.xquery(query, current_user[:id], current_user[:id]).each do |rel|
      key = (rel[:one] == current_user[:id] ? :another : :one)
      friends[rel[key]] ||= rel[:created_at]
    end
    list = friends.map{|user_id, created_at| [user_id, created_at]}
    erb :friends, locals: { friends: list }
  end

  post '/friends/:account_name' do
    authenticated!
    unless is_friend_account?(params['account_name'])
      user = user_from_account(params['account_name'])
      unless user
        raise Isucon5::ContentNotFound
      end
      db.xquery('INSERT INTO relations (one, another) VALUES (?,?), (?,?)', current_user[:id], user[:id], user[:id], current_user[:id])
      current_friends[user[:id]] = Time.now
      redirect '/friends'
    end
  end

  get '/initialize' do
    redis.keys('isucon5-*').each_slice(100) do |ks|
      redis.del(*ks)
    end
    db.query("DELETE FROM relations WHERE id > 500000")
    db.query("DELETE FROM footprints WHERE id > 500000")
    db.query("DELETE FROM entries WHERE id > 500000")
    db.query("DELETE FROM comments WHERE id > 1500000")
  end
end
