name: Create Post
description: Create a new post
method: POST
url: https://jsonplaceholder.typicode.com/posts
headers:
  - Content-Type: application/json
  - Accept: application/json
body:
  type: json
  content: |
    {
      "title": "Test from Volt collection",
      "body": "Automated collection run",
      "userId": 1
    }
tests:
  - status equals 201
  - $.title equals Test from Volt collection
