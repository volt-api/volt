name: WebSocket Echo
method: GET
url: ws://127.0.0.1:9090/ws/echo
headers:
  - Upgrade: websocket
  - Connection: Upgrade
  - Sec-WebSocket-Version: 13
