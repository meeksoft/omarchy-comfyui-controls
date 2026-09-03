# Tests

The test suite will cover the controller's observable states with fake HTTP
servers and subprocesses. Required cases include:

- free port starts exactly one managed server
- healthy existing ComfyUI instance is reused
- concurrent start requests create only one server
- unrelated listener produces `foreign-port`
- stop refuses to terminate an unowned process
- malformed or unavailable API responses produce a safe error state
- paths containing spaces are passed as arguments without shell evaluation

