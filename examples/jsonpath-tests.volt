name: JSONPath Assertions
description: Test specific JSON fields using JSONPath syntax
method: GET
url: https://jsonplaceholder.typicode.com/users/1
headers:
  - Accept: application/json
tests:
  - status equals 200
  - $.name equals Leanne Graham
  - $.email equals Sincere@april.biz
  - $.address.city equals Gwenborough
  - $.company.name equals Romaguera-Crona
