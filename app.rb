require "redis"
require "optparse"
require "dotenv/load"
require "uri"
require "webrick"
require "webrick/httpproxy"
require "net/http"
require "json"

redis = Redis.new(url: ENV.fetch("REDIS_URL", nil))
options = {}

parser = OptionParser.new do |opts|
  opts.banner = "Usage: app.rb [options] [options]"

  opts.on("-p", "--port PORT", "Is the port on which the caching proxy server will run") { |t| options[:port] = t.to_i }
  opts.on("-o", "--origin ORIGIN", "Is the URL of the server to which the requests will be forwarded") { |t| options[:origin] = t }

  opts.on("-h", "--help", "Show helps") { puts opts; exit }
end

begin
  parser.parse!
rescue OptionParser::ParseError => e
  warn e.message
  warn parser
end

if options[:port].nil? || options[:origin].nil?
  warn "Missing Port or Origin. \n\n#{parser}"
  exit 2
elsif redis.to_s.strip.nil?
  warn "Missing Redis url"
  exit 2
end

server = WEBrick::HTTPServer.new(Port: options[:port])
trap 'INT' do server.shutdown end

server.mount_proc '/' do |req, res|
  key = "#{options[:origin]}#{req.path}"

  if (cache = redis.get(key))
    parsed = JSON.parse(cache)
    puts "Cache HITED"
  else
    response = Net::HTTP.get_response(URI.parse(key))
    parsed = JSON.parse(response.body)
    redis.set(key, parsed.to_json, ex: 15 * 60)
  end

  res.body = JSON.pretty_generate(parsed.to_json)
end

server.start

