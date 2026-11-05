import Feed.Spec.Sha256

/-!
# SHA-256 and HMAC-SHA256: the test vectors and the constants

`Feed/Spec/Sha256.lean` against the published examples, and its two tables against the numbers
they are made from.

The examples are checks that the build runs: `#guard` evaluates each one with Lean's interpreter
(not in the kernel) and stops the build if it is false. `Sha256.hash_spec` and
`Hmac.mac_spec` (`Feed/Proofs/Sha256.lean`) hold for every input, so the code gives the same
digests.

* SHA-256: NIST's two examples for FIPS 180-4 (`abc`, one block; the 448-bit message, which pads
  to two), the empty message, the 896-bit message of the SHA-512 examples, and 1,000 bytes `a`
  (sixteen blocks, with the digest `sha256sum` prints);
* HMAC-SHA256: the seven test cases of RFC 4231 §4 (case 5 truncated to 128 bits, as printed),
  and the empty message under the keys of cases 2 and 6 (with the MACs that OpenSSL and
  Python's `hmac` give; the self-test checks the C `Hmac.mac` against the same values).

The tables are theorems, checked by the kernel: `K` is "the first thirty-two bits of the
fractional parts of the cube roots of the first sixty-four prime numbers" (§4.2.2) and `H0` the
same of the square roots of the first eight (§5.3.3), with the roots computed by `iroot`, which
`iroot_spec` shows is the integer root.
-/
namespace Feed.Spec.SHA256

/-- The bytes that a string of lowercase hexadecimal digits writes, two digits a byte. -/
def ofHex (s : String) : List UInt8 := go s.toList
where
  digit (c : Char) : Nat := if c.toNat < 0x3a then c.toNat - 0x30 else c.toNat - 0x57
  go : List Char → List UInt8
    | a :: b :: rest => (digit a * 16 + digit b).toUInt8 :: go rest
    | _ => []

/-- The bytes of a string (its UTF-8 encoding). -/
def bytesOf (s : String) : List UInt8 := s.toUTF8.toList

#guard sha256 (bytesOf "abc") ==
  ofHex "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
#guard sha256 (bytesOf "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq") ==
  ofHex "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
#guard sha256 [] ==
  ofHex "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
#guard sha256 (bytesOf ("abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmno" ++
    "ijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu")) ==
  ofHex "cf5b16a778af8380036ce59e7b0492370b249b11e8f07a51afac45037afee9d1"
#guard sha256 (List.replicate 1000 0x61) ==
  ofHex "41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3"

/-! ## The constants -/

/-- Whether `n` is prime: `n ≥ 2` and no number in `[2, n)` divides it. -/
def isPrime (n : Nat) : Bool := 2 ≤ n && (List.range' 2 (n - 2)).all (n % · != 0)

/-- `iroot r x b y`: `y` with the bits below `2 ^ b` set one at a time from the top, each kept if
the `r`-th power stays at most `x`. -/
def iroot (r x : Nat) : Nat → Nat → Nat
  | 0, y => y
  | b + 1, y => let y' := y + 2 ^ b; iroot r x b (if y' ^ r ≤ x then y' else y)

/-- `iroot r x b 0` is the integer `r`-th root of `x < (2 ^ b) ^ r`: the `z` with
`z ^ r ≤ x < (z + 1) ^ r`. -/
theorem iroot_spec (r x b : Nat) (hr : 0 < r) (hx : x < (2 ^ b) ^ r) :
    iroot r x b 0 ^ r ≤ x ∧ x < (iroot r x b 0 + 1) ^ r := by
  suffices h : ∀ b y, y ^ r ≤ x → x < (y + 2 ^ b) ^ r →
      iroot r x b y ^ r ≤ x ∧ x < (iroot r x b y + 1) ^ r from
    h b 0 (by rw [Nat.zero_pow hr]; exact Nat.zero_le x) (by rwa [Nat.zero_add])
  intro b
  induction b with
  | zero => intro y h1 h2; exact ⟨h1, by rwa [Nat.pow_zero] at h2⟩
  | succ b ih =>
    intro y h1 h2
    simp only [iroot]
    split
    · rename_i h
      exact ih _ h (by rwa [Nat.add_assoc, ← Nat.two_mul, ← Nat.pow_succ'])
    · rename_i h
      exact ih _ h1 (Nat.lt_of_not_le h)

/-- §4.2.2: `K` from the cube roots of the first 64 primes (the 64th is 311): the bits below
2^32 of `⌊∛p · 2^32⌋ = iroot 3 (p · 2^96)`. -/
theorem K_eq_cube_roots : K = (((List.range 312).filter isPrime).take 64).map
    fun p => (iroot 3 (p * 2 ^ 96) 40 0 % 2 ^ 32).toUInt32 := by
  decide +kernel

/-- info: 'Feed.Spec.SHA256.K_eq_cube_roots' does not depend on any axioms -/
#guard_msgs in #print axioms K_eq_cube_roots

/-- §5.3.3: `H0` from the square roots of the first 8 primes: the bits below 2^32 of
`⌊√p · 2^32⌋ = iroot 2 (p · 2^64)`. -/
theorem H0_eq_square_roots : [H0.a, H0.b, H0.c, H0.d, H0.e, H0.f, H0.g, H0.h] =
    (((List.range 20).filter isPrime).take 8).map
      fun p => (iroot 2 (p * 2 ^ 64) 40 0 % 2 ^ 32).toUInt32 := by
  decide +kernel

/-- info: 'Feed.Spec.SHA256.H0_eq_square_roots' does not depend on any axioms -/
#guard_msgs in #print axioms H0_eq_square_roots

end Feed.Spec.SHA256

namespace Feed.Spec.HMAC
open Feed.Spec.SHA256 (ofHex bytesOf)

#guard hmacSha256 (List.replicate 20 0x0b) (bytesOf "Hi There") ==
  ofHex "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7"
#guard hmacSha256 (bytesOf "Jefe") (bytesOf "what do ya want for nothing?") ==
  ofHex "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843"
#guard hmacSha256 (List.replicate 20 0xaa) (List.replicate 50 0xdd) ==
  ofHex "773ea91e36800e46854db8ebd09181a72959098b3ef8c122d9635514ced565fe"
#guard hmacSha256 ((List.range' 1 25).map (·.toUInt8)) (List.replicate 50 0xcd) ==
  ofHex "82558a389a443c0ea4cc819899f2083a85f0faa3e578f8077a2e3ff46729665b"
#guard (hmacSha256 (List.replicate 20 0x0c) (bytesOf "Test With Truncation")).take 16 ==
  ofHex "a3b6167473100ee06e0c796c2955552b"
#guard hmacSha256 (List.replicate 131 0xaa)
    (bytesOf "Test Using Larger Than Block-Size Key - Hash Key First") ==
  ofHex "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54"
#guard hmacSha256 (List.replicate 131 0xaa) (bytesOf ("This is a test using a larger than " ++
    "block-size key and a larger than block-size data. The key needs to be hashed before being " ++
    "used by the HMAC algorithm.")) ==
  ofHex "9b09ffa71b942fcb27635fbcd5b0e944bfdc63644f0713938a7f51535c3a35e2"
#guard hmacSha256 (bytesOf "Jefe") [] ==
  ofHex "923598ca6d64af2a5dba79dcd021a8a0fe5c5f557519adaaf0ad532d4506dd30"
#guard hmacSha256 (List.replicate 131 0xaa) [] ==
  ofHex "44b545def5b97eb719d856a15e327833e520e4770619c0e3eefbde24b71285a7"

end Feed.Spec.HMAC
