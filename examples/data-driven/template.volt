name: Create Post (Data-Driven)
description: Run this with --data to test multiple inputs
method: POST
url: https://jsonplaceholder.typicode.com/posts
headers:
  - Content-Type: application/json
body:
  type: json
  content: |
    {
      "title": "{{title}}",
      "body": "{{body}}",
      "userId": {{userId}}
    }
tests:
  - status equals 201
  - body contains title
