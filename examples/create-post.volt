name: Create Post
method: POST
url: https://jsonplaceholder.typicode.com/posts
headers:
  - Content-Type: application/json
  - Accept: application/json
body:
  type: json
  content: |
    {
      "title": "Hello from Volt",
      "body": "This request was sent using Volt API client",
      "userId": 1
    }
tests:
  - status equals 201
  - body contains title
