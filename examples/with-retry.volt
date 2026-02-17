name: Retry Example
description: Demonstrates retry on transient failure
method: GET
url: https://httpbin.org/get
headers:
  - Accept: application/json
tests:
  - status equals 200
