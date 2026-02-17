name: Example Request
method: GET
url: https://httpbin.org/get
headers:
  - Accept: application/json
  - User-Agent: Volt/1.0.0
tests:
  - status equals 200
  - header.content-type contains application/json
