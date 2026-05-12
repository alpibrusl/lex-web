# lex-web — test fixtures
#
# Provides sample Validators for use in tests and examples.
#
# Effects: none.

import "lex-data/schema"      as s
import "lex-data/constraints" as c
import "lex-data/validator"   as v

# A two-field validator (name: string, qty: integer) used in
# OpenAPI and body decoding tests.
fn item_validator() -> v.Validator {
  v.make({
    title: "Item", description: "",
    fields: [
      s.required_str("name", [StrNonEmpty]),
      s.required_int("qty",  [IntPositive]),
    ],
  })
}

# A single-field validator used in simple body tests.
fn name_validator() -> v.Validator {
  v.make({
    title: "Name", description: "",
    fields: [
      s.required_str("name", [StrNonEmpty]),
    ],
  })
}
