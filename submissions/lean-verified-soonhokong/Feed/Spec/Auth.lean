import Feed.Spec.Errors
import Feed.Spec.Json
import Feed.Spec.Base64

/-!
# The token

SPEC.md "## Auth" (SPEC.md:76-78) and its three 401 rows (SPEC.md:64-66), with the checks of
RFC 7515 §5.2 (a JWS in the compact serialization), RFC 7519 §4.1 and §7.2 (a JWT's claims) and
RFC 7518 §3.2 (HS256).

Where SPEC.md and the RFCs leave room, these are this server's choices: `exp` is required
(SPEC.md:77 asks to verify it; RFC 7519 §4.1.4 makes it optional); a header with `crit`, a
payload with `aud` (no audience is configured) and a nested JWT (`cty` JWT) make a token
invalid; a member given twice counts with its last value; `sub` is a positive integer written as
`String(n)` writes it, below 10^18; "Bearer " is matched as SPEC.md:64 writes it. RFC 7518 §3.2
asks that the MAC be compared in constant time; this specification says nothing of timing.
-/
namespace Feed.Spec.Auth
open Json

abbrev Bytes := List UInt8

/-- a member name, as UTF-16 code units (RFC 8259 §8.3) -/
def name (s : String) : List Nat := (lit s).map (·.toNat)

open Classical in
/-- RFC 7515 §5.2 (3), RFC 7519 §7.2 (10): the members of a JSON text that is an object
(`Json.IsObjectText`, which is UTF-8 by construction); unique by `IsObjectText.unique` -/
noncomputable def objectMembers (t : Bytes) : Option (List (List Nat × Bytes)) :=
  if h : ∃ ms, IsObjectText t ms then some (Classical.choose h) else none

open Classical in
/-- the UTF-8 text of a JSON string value (lone surrogates as U+FFFD); unique by `IsString.unique` -/
noncomputable def stringValue (v : Bytes) : Option Bytes :=
  if h : ∃ us, IsString v us then some (encode (scalars (Classical.choose h))) else none

def IsNum (v : Bytes) : Prop := ∃ neg m e, IsNumber v neg m e

def asciiLower (s : Bytes) : Bytes := s.map fun b => if 0x41 ≤ b ∧ b ≤ 0x5a then b + 32 else b

/-- RFC 7519 §7.2 (8) with RFC 7515 §4.1.10: a `cty` naming a nested JWT -/
def nestedCty (s : Bytes) : Bool := asciiLower s == lit "jwt" || asciiLower s == lit "application/jwt"

/-- `sub`: a positive integer as `String(n)` writes it (digits, no sign, no leading zero), below
10^18 (SPEC.md:83 puts ids beyond 2^53 out of scope) -/
def subjectId : Bytes → Option Nat
  | [] => none
  | s@(c :: _) => if c = 0x30 ∨ s.length > 18 then none else decimal s 0

inductive TokenCheck where
  /-- SPEC.md:65 "bad signature, expired, not HS256, or malformed JWT" -/
  | invalid
  /-- SPEC.md:66 "valid JWT, but `sub` isn't a positive integer string or `username` isn't a string" -/
  | badPayload
  | ok (uid : Nat) (username : Bytes)

open Classical in
/-- The token `t` at time `now` (whole seconds); `mac m` is HMAC-SHA256 of `m` under JWT_SECRET. -/
noncomputable def checkToken (mac : Bytes → Bytes) (now : Nat) (t : Bytes) : TokenCheck :=
  match t.splitOn 0x2e with                                                 -- RFC 7515 §7.1
  | [h, p, s] =>
    match b64urlDecode h, b64urlDecode p, b64urlDecode s with               -- §5.2 (2), (6), (7)
    | some hb, some pb, some sb =>
      match objectMembers hb, objectMembers pb with                         -- §5.2 (3); 7519 §7.2 (10)
      | some hdr, some cl =>
        if (member hdr (name "alg")).bind stringValue ≠ some (lit "HS256") then .invalid  -- SPEC.md:77
        else if (member hdr (name "crit")).isSome then .invalid                        -- 7515 §4.1.11
        else if ((member hdr (name "cty")).bind stringValue).any nestedCty then .invalid  -- 7519 §7.2 (8)
        else if sb ≠ mac (h ++ [0x2e] ++ p) then .invalid                              -- 7518 §3.2
        else if ¬ ∃ v, member cl (name "exp") = some v ∧ NumGt v now then .invalid      -- 7519 §4.1.4
        else if ∃ v, member cl (name "nbf") = some v ∧ (¬ IsNum v ∨ NumGt v now) then .invalid  -- §4.1.5
        else if (member cl (name "aud")).isSome then .invalid                           -- 7519 §4.1.3
        else
          match (member cl (name "sub")).bind stringValue, (member cl (name "username")).bind stringValue with
          | some s, some u =>
            match subjectId s with
            | some uid => .ok uid u
            | none => .badPayload
          | _, _ => .badPayload
      | _, _ => .invalid
    | _, _, _ => .invalid
  | _ => .invalid

/-- SPEC.md "Auth" and the three 401 rows: the user a request is authenticated as. `authz` is the
Authorization field value (RFC 9110 §5.5: without surrounding whitespace); "Bearer " is matched
literally, as SPEC.md:64 writes it (RFC 9110 §11.1's case-insensitive scheme is not adopted). -/
noncomputable def authenticate (mac : Bytes → Bytes) (now : Nat) (authz : Option Bytes) :
    Except ApiErr (Nat × Bytes) :=
  match authz.bind (dropPrefix (lit "Bearer ")) with
  | none => .error .missingBearer
  | some t =>
    match checkToken mac now t with
    | .invalid => .error .invalidToken
    | .badPayload => .error .invalidPayload
    | .ok uid u => .ok (uid, u)

end Feed.Spec.Auth
