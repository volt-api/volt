name: Proxy Capture
method: GET
url: http://127.0.0.1:9090/proxy-target
headers:
  - X-Proxy-Capture: true
  - X-Forwarded-For: 10.0.0.1
  - Accept: application/json
variables:
  proxy_port: 8888
tests:
  - status equals 200
