name: Request with Pre/Post Scripts
method: GET
url: https://jsonplaceholder.typicode.com/posts/1
headers:
  - Accept: application/json
pre_script: |
  log Starting request...
  set request_time now
post_script: |
  log Response received
  extract title body.title
  assert status == 200
tests:
  - status equals 200
  - body contains userId
