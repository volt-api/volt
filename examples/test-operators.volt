name: Test Assertion Operators
description: Demonstrates all test assertion operators
method: GET
url: https://jsonplaceholder.typicode.com/users/1
headers:
  - Accept: application/json
tests:
  - status equals 200
  - status != 404
  - status < 300
  - status > 100
  - body contains Leanne
  - header.content-type contains json
  - $.name equals Leanne Graham
  - $.name != John Doe
  - $.id exists
  - $.address.city equals Gwenborough
