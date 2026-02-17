name: Basic Auth Endpoint
description: Demonstrates basic username/password authentication
method: GET
url: https://httpbin.org/basic-auth/voltuser/voltpass
auth:
  type: basic
  username: voltuser
  password: voltpass
headers:
  - Accept: application/json
tests:
  - status equals 200
  - body contains authenticated
