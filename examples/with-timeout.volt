name: Timeout Example
description: Request with a per-request timeout
method: GET
url: https://httpbin.org/delay/1
timeout: 5000
headers:
  - Accept: application/json
tests:
  - status equals 200
