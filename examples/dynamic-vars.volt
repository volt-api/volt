name: Dynamic Variables
description: Uses auto-generated values on each run
method: POST
url: https://jsonplaceholder.typicode.com/posts
headers:
  - Content-Type: application/json
  - X-Request-ID: {{$uuid}}
body:
  type: json
  content: |
    {
      "title": "Post at {{$isoDate}}",
      "body": "Random value: {{$randomInt}}",
      "userId": 1
    }
tests:
  - status equals 201
