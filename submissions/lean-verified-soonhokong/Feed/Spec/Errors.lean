import Feed.Spec

/-!
# The API's errors

SPEC.md "## Errors" (SPEC.md:57-70) as a type. Which row a request falls in is decided by the
other specification modules: `Feed/Spec/Auth.lean` (the 401 rows), `Feed/Spec/Body.lean` (the
body rows and 500) and `Feed/Spec/Server.lean` (the routes).
-/
namespace Feed.Spec

/-- The rows of SPEC.md's error table, in its order. -/
inductive ApiErr where
  | notFound | invalidId | postNotFound | missingBearer | invalidToken | invalidPayload
  | malformedJson | bodyRequired | bodyTooLong | internal
  deriving DecidableEq, Repr, Inhabited

/-- The status of each row (SPEC.md:61-70). -/
def ApiErr.status : ApiErr → Nat
  | .notFound | .postNotFound => 404
  | .invalidId | .malformedJson | .bodyRequired | .bodyTooLong => 400
  | .missingBearer | .invalidToken | .invalidPayload => 401
  | .internal => 500

/-- The message of each row (SPEC.md:61-70). -/
def ApiErr.message : ApiErr → String
  | .notFound => "not found"
  | .invalidId => "invalid post id"
  | .postNotFound => "post not found"
  | .missingBearer => "missing bearer token"
  | .invalidToken => "invalid or expired token"
  | .invalidPayload => "invalid token payload"
  | .malformedJson => "malformed JSON body"
  | .bodyRequired => "body is required"
  | .bodyTooLong => "body must be at most 500 characters"
  | .internal => "internal server error"

/-- SPEC.md:57: "Every error body is `{"error":"<message>"}`." -/
def ApiErr.body (e : ApiErr) : List UInt8 := errJson e.message

end Feed.Spec
