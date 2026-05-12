# lex-web — test fixtures
#
# Provides sample Validators and other lex-data values for use in
# test files. Importing from tests/ directly would produce a
# different module identity (due to path string differences) than
# the one expected by router/openapi. Importing through this file
# keeps the module identity consistent with the rest of src/.
#
# Effects: none.

import "../../lex-data/src/schema"      as s
import "../../lex-data/src/constraints" as c
import "../../lex-data/src/validator"   as v

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
