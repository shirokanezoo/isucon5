require 'logger'

worker_processes 4
preload_app true
listen 8080
pid "/home/isucon/webapp/ruby/unicorn.pid"
stderr_path "/tmp/unicorn-err.log"
stdout_path "/tmp/unicorn-out.log"
logger Logger.new($stderr).tap{|l| l.formatter = Logger::Formatter.new }

before_fork do |server, worker|
  #if defined?(ActiveRecord::Base)
  #  ActiveRecord::Base.connection_handler.connection_pools.map  {|name, pool| pool.connections }.flatten.each { |c| c.disconnect! }
  #end

  old_pid_path = "/home/isucon/webapp/ruby/unicorn.pid.oldbin"
  if File.exists?(old_pid_path) && server.pid != old_pid_path
    begin
      Process.kill("QUIT", File.read(old_pid_path).to_i)
    rescue Errno::ENOENT, Errno::ESRCH
      # someone else did our job for us
    end
  end
end

after_fork do |server, worker|
  if defined?(Redis) && Redis.current.connected?
    Redis.current.client.reconnect
  end
end
