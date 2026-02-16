name: List Posts
description: Get all posts
method: GET
url: https://jsonplaceholder.typicode.com/posts
headers:
  - Accept: application/json
tests:
  - status equals 200
  - header.content-type contains json
