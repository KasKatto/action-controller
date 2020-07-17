require "./logger"

module ActionController
  # A handler that logs the request method, resource, status code, and the time
  # taken to execute.
  class LogHandler
    include HTTP::Handler

    # Events that occur within the request lifecycle.
    @[Flags]
    enum Event
      Request
      Response
      def self.all
        Request | Response
      end
    end

    # Creates a new `LogHandler` for inserting into middlewhere.
    #
    # Use *filter* to specified any keys that may appear in request params that
    # should be redacted prior to passing to the logging backend. This may
    # include secrets or PII that should not leave the bounds of this system.
    #
    # *log* can be used to specify what sections of the request lifecycle to
    # log. The defaults to the response (either valid or error) only, however
    # support is also provide for request entry logging for development
    # environments.
    def initialize(@filter = [] of String, @log = Event::Response)
    end

    private getter filter

    private getter log

    def call(context : HTTP::Server::Context) : Nil
      ::Log.with_context do
        emit_request context if log.request?

        start = Time.monotonic
        duration = Time::Span::ZERO

        begin
          begin
            call_next context
          ensure
            duration = Time.monotonic - start
          end
          emit_response context, duration if log.response?
        rescue e
          emit_error context, duration, e if log.response?
          raise e
        end
      end
    end

    # Emits an inbound request message for the passed `Context`.
    private def emit_request(context : HTTP::Server::Context)
      Log.info &.emit(
        event: "request",
        method: context.request.method,
        path: filter_path(context.request.resource)
      )
    end

    # Emits a response entry.
    private def emit_response(context : HTTP::Server::Context, duration : Time::Span)
      Log.info &.emit(
        event: "response",
        method: context.request.method,
        path: filter_path(context.request.resource),
        status: context.response.status_code,
        duration: elapsed_text(duration)
      )
    end

    # Emits an error entry.
    private def emit_error(context : HTTP::Server::Context, duration : Time::Span, e : Exception)
      Log.error(exception: e, &.emit(
        event: "error",
        method: context.request.method,
        path: filter_path(context.request.resource),
        status: 500,
        duration: elapsed_text(duration)
      ))
    end

    private def elapsed_text(elapsed)
      minutes = elapsed.total_minutes
      return "#{minutes.round(2)}m" if minutes >= 1

      seconds = elapsed.total_seconds
      return "#{seconds.round(2)}s" if seconds >= 1

      millis = elapsed.total_milliseconds
      return "#{millis.round(2)}ms" if millis >= 1

      "#{(millis * 1000).round(2)}µs"
    end

    private def filter_path(path)
      return path if @filter.empty?
      path.gsub(/(\?|\&)([^&;=]+)=([^&;=]+)/) do |value|
        filter = false
        @filter.each do |key|
          if $2 == key
            filter = true
            break
          end
        end
        filter ? "#{$1}#{$2}=[FILTERED]" : value
      end
    end
  end
end
