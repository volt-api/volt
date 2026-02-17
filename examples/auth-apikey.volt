name: API Key Auth Endpoint
description: Demonstrates API key authentication via header
method: GET
url: https://httpbin.org/headers
auth:
  type: api_key
  key_name: X-Api-Key
  key_value: demo-api-key-12345
  key_location: header
headers:
  - Accept: application/json
tests:
  - status equals 200
  - body contains X-Api-Key
