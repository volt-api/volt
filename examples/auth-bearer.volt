name: Protected Endpoint
description: Demonstrates bearer token authentication
method: GET
url: https://httpbin.org/bearer
auth:
  type: bearer
  token: my-secret-token-123
headers:
  - Accept: application/json
tests:
  - status equals 200
  - body contains authenticated
