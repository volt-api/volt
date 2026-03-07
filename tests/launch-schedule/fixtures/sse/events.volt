name: SSE Event Stream
method: GET
url: http://127.0.0.1:9090/sse/events
headers:
  - Accept: text/event-stream
  - Cache-Control: no-cache
tests:
  - status equals 200
