name: Output to File Test
description: Used to test --output flag
method: GET
url: https://httpbin.org/json
headers:
  - Accept: application/json
tests:
  - status equals 200
