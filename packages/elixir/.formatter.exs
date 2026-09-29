[
  import_deps: [:plug],
  # Phoenix.Router's forward, in the tests (Phoenix is a test-only dependency).
  locals_without_parens: [forward: 3],
  inputs: ["{mix,.formatter,.credo}.exs", "{config,lib,test}/**/*.{ex,exs}"],
  line_length: 120
]
