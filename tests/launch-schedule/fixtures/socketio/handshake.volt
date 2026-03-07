name: Socket.IO Handshake
method: GET
url: http://127.0.0.1:9090/socket.io/?EIO=4&transport=polling
headers:
  - Accept: application/octet-stream
  - Connection: keep-alive
tests:
  - status equals 200
