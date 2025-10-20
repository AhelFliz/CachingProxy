#! /usr/bin/env ruby

require "redis"
require "optparse"
require "dotenv/load"
require "uri"
require "webrick"
require "webrick/httpproxy"
require "net/http"
require "json"

redis = Redis.new(url: ENV.fetch("REDIS_URL", "redis://127.0.0.1:6379/0"))
options = {}

parser = OptionParser.new do |opts|
  opts.banner = "Usage: app.rb [options] [options]"

  opts.on("-p", "--port PORT", "Is the port on which the caching proxy server will run") { |t| options[:port] = t.to_i }
  opts.on("-o", "--origin ORIGIN", "Is the URL of the server to which the requests will be forwarded") { |t| options[:origin] = t }
  opts.on("-c", "--clear_cache", "Clear cache (remove all keys saved)") { |t| options[:clear_cache] = t }

  opts.on("-h", "--help", "Show helps") { puts opts; exit }
end

begin
  parser.parse!
rescue OptionParser::ParseError => e
  warn e.message
  warn parser
end

if options[:clear_cache]
  redis.flushall
  puts "Keys after flushall: #{redis.keys}"
  exit
elsif options[:port].nil? || options[:origin].nil?
  warn "Missing Port or Origin. \n\n#{parser}"
  exit 2
elsif redis.to_s.strip.nil?
  warn "Missing Redis url"
  exit 2
end

server = WEBrick::HTTPServer.new(Port: options[:port])
trap 'INT' do server.shutdown end

server.mount_proc '/' do |req, res|
  uri = URI.join(options[:origin], req.path)
  qs = req.query_string.to_s
  uri.query = qs unless qs.empty?

  key = "#{req.request_method} #{uri}"

  if (cache = redis.get(key))
    entry = JSON.parse(cache)
    res.status = entry["status"]
    res['Content-Type'] = entry["content_type"] if entry["content_type"]
    res['X-Cache'] = 'HIT'
    res.body = entry["body"]
  else
    begin
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https') do |http|
        http.read_timeout = 5
        http.request(Net::HTTP::Get.new(uri.request_uri))
      end

      entry = {
        "status" => response.code.to_i,
        "content_type" => response['content-type'],
        "body" => response.body
      }

      redis.set(key, JSON.generate(entry), ex: 15 * 60)

      res.status = entry["status"]
      res['Content-Type'] = entry["content_type"] if entry["content_type"]
      res['X-Cache'] = 'MISS'
      res.body = entry["body"]
    rescue => e
      res.status = 502
      res['Content-Type'] = 'text/plain'
      res['X-Cache'] = 'MISS'
      res.body = "Bad Gatway: #{e.class} - #{e.message}"
    end
  end
end

server.start

