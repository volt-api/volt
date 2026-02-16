name: Health Check
description: Verify API is running
method: GET
url: https://jsonplaceholder.typicode.com/posts/1
headers:
  - Accept: application/json
tests:
  - status equals 200
