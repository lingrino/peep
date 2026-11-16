require "http/server"

class Greeter
  def initialize(@name : String = "world")
  end

  def call(context : HTTP::Server::Context)
    context.response.content_type = "text/plain"
    context.response.print "Hello, #{@name}!"
  end
end

server = HTTP::Server.new([Greeter.new("Peep")])
puts "Listening on http://127.0.0.1:8080"
server.listen(8080)
